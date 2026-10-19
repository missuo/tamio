//
//  SyncSession.swift
//  TamioModule
//
//  One round of sync as a function: what this device has, what the store
//  holds, and out of them what to change here and what to upload. It touches
//  neither the store nor the app, so it runs off the main thread.
//

import Foundation

struct SyncInput: Sendable {
    var machines: [RDMachine]
    var identities: [RDIdentity]
    var snippets: [RDSnippet] = []
    var portForwards: [RDPortForward] = []
    var knownHosts: [KnownHostEntry] = []
    var preferences: [PreferenceItem] = []
    /// The keys of the preferences this device has, synced or not. One it
    /// lacks (from a later version, or another kind of device) is kept as it
    /// was stored rather than taken for deleted here.
    var preferenceKeys: Set<String> = []
    var activity: [AgentActivity] = []
    /// When this device's activity log was last cleared.
    var activityClearedAt: Date?
    var state: SyncState
    var passphrase: String
    /// The stored envelope, if there is one.
    var remote: Data?
    /// A key derived earlier, to save deriving it again.
    var key: SyncCipher.Key?
    var syncsMachines = true
    var syncsIdentities = true
    var syncsSnippets = true
    var syncsPortForwards = true
    var syncsKnownHosts = true
    var syncsPreferences = true
    var syncsActivity = true
    /// Seal under a new key from `passphrase`, whatever is stored. What is
    /// stored is merged first if `key`, the one in use until now, still opens
    /// it; otherwise this device's data takes its place.
    var replacesRemote = false
    var now = Date()
    var rounds = SyncCipher.rounds
    var minimumRounds = SyncCipher.minimumRounds
}

enum SyncOutcome: Sendable {
    case done(Done)
    /// The passphrase does not open what is stored.
    case locked
    /// What is stored is not something this version wrote.
    case unreadable
    /// What is stored was written by a later version.
    case newer

    struct Done: Sendable {
        var machines: [SyncChange<RDMachine>]
        var identities: [SyncChange<RDIdentity>]
        var snippets: [SyncChange<RDSnippet>] = []
        var portForwards: [SyncChange<RDPortForward>] = []
        var knownHosts: [SyncChange<KnownHostEntry>] = []
        var preferences: [SyncChange<PreferenceItem>] = []
        /// Activity of other devices to add to this one's log.
        var activity: [AgentActivity] = []
        var state: SyncState
        var key: SyncCipher.Key
        /// The envelope to store, when it changed.
        var upload: Data?
    }
}

enum SyncSession {
    static func run(_ input: SyncInput) -> SyncOutcome {
        var document = SyncDocument()
        var key = input.replacesRemote ? nil : input.key
        var stored = false

        if input.replacesRemote {
            if let remote = input.remote, let old = input.key,
               let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: remote),
               envelope.version <= SyncEnvelope.currentVersion,
               envelope.salt == old.salt, envelope.rounds == old.rounds,
               let plain = try? SyncCipher.open(envelope, with: old),
               let decoded = try? JSONDecoder().decode(SyncDocument.self, from: plain)
            {
                document = decoded
            }
        } else if let remote = input.remote {
            guard let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: remote) else {
                return .unreadable
            }
            guard envelope.version <= SyncEnvelope.currentVersion else { return .newer }
            guard (input.minimumRounds ... SyncCipher.maximumRounds).contains(envelope.rounds),
                  envelope.salt.count >= 8
            else { return .unreadable }
            if key?.salt != envelope.salt || key?.rounds != envelope.rounds {
                key = SyncCipher.key(passphrase: input.passphrase, salt: envelope.salt, rounds: envelope.rounds)
            }
            guard let key else { return .locked }
            let plain: Data
            do {
                plain = try SyncCipher.open(envelope, with: key)
            } catch SyncCipher.OpenError.wrongPassphrase {
                return .locked
            } catch {
                // Damaged data is not a wrong passphrase: asking for another
                // one would not help.
                return .unreadable
            }
            guard let decoded = try? JSONDecoder().decode(SyncDocument.self, from: plain) else {
                return .unreadable
            }
            document = decoded
            stored = true
        }

        let sealing = key ?? SyncCipher.key(
            passphrase: input.passphrase, salt: SyncCipher.newSalt(), rounds: input.rounds
        )
        var state = input.state
        var dirty = !stored
        var done = SyncOutcome.Done(machines: [], identities: [], state: state, key: sealing)

        // Each kind is merged on its own; one that is not synced here is
        // passed on as it was stored.
        func merge<Value: SyncItem>(
            _ syncs: Bool, _ local: [Value],
            _ stamps: WritableKeyPath<SyncState, [String: SyncState.Stamp]>,
            _ entries: WritableKeyPath<SyncDocument, [String: SyncDocument.Entry<Value>]>,
            _ changes: WritableKeyPath<SyncOutcome.Done, [SyncChange<Value>]>
        ) {
            guard syncs else { return }
            let merged = SyncMerge.reconcile(
                local: local, state: &state[keyPath: stamps], remote: document[keyPath: entries], now: input.now
            )
            document[keyPath: entries] = merged.entries
            done[keyPath: changes] = merged.changes
            dirty = dirty || merged.dirty
        }
        merge(input.syncsMachines, input.machines, \.machines, \.machines, \.machines)
        merge(input.syncsIdentities, input.identities, \.identities, \.identities, \.identities)
        merge(input.syncsSnippets, input.snippets, \.snippets, \.snippets, \.snippets)
        merge(input.syncsPortForwards, input.portForwards, \.portForwards, \.portForwards, \.portForwards)
        merge(input.syncsKnownHosts, input.knownHosts, \.knownHosts, \.knownHosts, \.knownHosts)
        let foreign = document.preferences.values.compactMap(\.value).filter { !input.preferenceKeys.contains($0.key) }
        merge(input.syncsPreferences, input.preferences + foreign, \.preferences, \.preferences, \.preferences)
        done.preferences.removeAll { change in
            if case let .put(item) = change { return !input.preferenceKeys.contains(item.key) }
            return false
        }
        if input.syncsActivity {
            let combined = SyncActivity.combine(
                local: input.activity, remote: document.activity, clearedAt: input.activityClearedAt
            )
            document.activity = combined.entries
            done.activity = combined.arrived
            dirty = dirty || combined.dirty
        }

        var upload: Data?
        if dirty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let plain = try? encoder.encode(document),
                  let sealed = try? SyncCipher.seal(plain, with: sealing)
            else { return .unreadable }
            upload = sealed
        }
        done.state = state
        done.upload = upload
        return .done(done)
    }
}
