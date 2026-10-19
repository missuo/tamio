//
//  CloudSync.swift
//  TamioModule
//
//  Keeps the servers, identities, snippets, port forwards, known hosts and
//  settings of this device and of the user's other devices the same, and their agent
//  activity together, through iCloud, sealed under a passphrase only the
//  devices know. It is on unless the user turns it off, so what agents did on
//  each server is not lost with a Mac: the passphrase is the one another
//  device shared in iCloud Keychain, or one Tamio makes and shares there.
//

import Combine
import Foundation
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@MainActor
public final class CloudSync: ObservableObject {
    public static let shared = CloudSync()

    public enum Status: Equatable {
        case off
        /// Sync cannot work here; the sentence says why.
        case unavailable(String)
        case syncing
        case synced(Date)
        /// This device's passphrase does not open what is in iCloud.
        case locked
        /// What is in iCloud cannot be read at all.
        case unreadable
        case failed(String)
    }

    @Published public private(set) var status: Status = .off
    @Published public private(set) var isOn: Bool

    @Published public var syncsServers: Bool {
        didSet {
            guard syncsServers != oldValue else { return }
            defaults.set(syncsServers, forKey: Key.servers)
            state.machines = [:]
            generation += 1
            sync()
        }
    }

    @Published public var syncsIdentities: Bool {
        didSet {
            guard syncsIdentities != oldValue else { return }
            defaults.set(syncsIdentities, forKey: Key.identities)
            state.identities = [:]
            generation += 1
            sync()
        }
    }

    @Published public var syncsSnippets: Bool { didSet { kindChanged(syncsSnippets, oldValue, Key.snippets) { $0.snippets = [:] } } }
    @Published public var syncsPortForwards: Bool { didSet { kindChanged(syncsPortForwards, oldValue, Key.portForwards) { $0.portForwards = [:] } } }
    @Published public var syncsKnownHosts: Bool { didSet { kindChanged(syncsKnownHosts, oldValue, Key.knownHosts) { $0.knownHosts = [:] } } }
    @Published public var syncsActivity: Bool { didSet { kindChanged(syncsActivity, oldValue, Key.activity) { _ in } } }
    @Published public var syncsSettings: Bool { didSet { kindChanged(syncsSettings, oldValue, Key.settings) { $0.preferences = [:] } } }

    /// The preferences in Settings that sync, handed over by the app before
    /// `start`.
    public var preferences: [SyncedPreference] = [] {
        didSet { preferenceValues = readPreferences() }
    }

    /// What `preferences` read last, to tell a change to one of them from
    /// the many other changes to the defaults.
    private var preferenceValues: [PreferenceItem] = []

    /// A kind turned on or off: what this device knew of it is forgotten, so
    /// turned on again it starts from what is stored.
    private func kindChanged(_ value: Bool, _ old: Bool, _ key: String, forget: (inout SyncState) -> Void) {
        guard value != old else { return }
        defaults.set(value, forKey: key)
        forget(&state)
        generation += 1
        sync()
    }

    /// Why sync cannot be turned on here, if it cannot.
    public var problem: String? {
        if !TamioStore.savesChanges { return String(localized: "Tamio could not read its key from the keychain, so nothing is saved or synced.") }
        return transport.problem
    }

    /// Whether iCloud already holds data, from this or another device.
    public var hasStoredData: Bool { transport.read() != nil }

    public static let minimumPassphraseLength = 8

    private enum Key {
        static let on = "sb.moe.tamio.sync.enabled"
        static let servers = "sb.moe.tamio.sync.servers"
        static let identities = "sb.moe.tamio.sync.identities"
        static let snippets = "sb.moe.tamio.sync.snippets"
        static let portForwards = "sb.moe.tamio.sync.portForwards"
        static let knownHosts = "sb.moe.tamio.sync.knownHosts"
        static let activity = "sb.moe.tamio.sync.activity"
        static let settings = "sb.moe.tamio.sync.settings"
        /// Turned off here by the user: the passphrase shared in iCloud
        /// Keychain does not turn it on again.
        static let optedOut = "sb.moe.tamio.sync.optedOut"
    }

    /// The passphrase as it is kept on the device: with the servers and
    /// identities, under the app's master key.
    private struct Secret: Codable {
        var passphrase: String
    }

    private let store = TamioStore.shared
    private let defaults = UserDefaults.standard
    private let transport: SyncTransport
    private var passphrase: String?
    private var state = SyncState() {
        didSet {
            guard state != oldValue else { return }
            store.storeEncryptedDefault(to: .syncState, with: state)
        }
    }

    private var key: SyncCipher.Key?
    private var running = false
    private var pending = false
    private var replacesNext = false
    private var started = false
    /// Counts the changes to what a round reads, to tell a round that was
    /// overtaken by one.
    private var generation = 0
    private var observers: Set<AnyCancellable> = []

    private init() {
        defaults.register(defaults: [
            Key.servers: true, Key.identities: true, Key.snippets: true,
            Key.portForwards: true, Key.knownHosts: true, Key.activity: true,
            Key.settings: true,
        ])
        isOn = defaults.bool(forKey: Key.on)
        syncsServers = defaults.bool(forKey: Key.servers)
        syncsIdentities = defaults.bool(forKey: Key.identities)
        syncsSnippets = defaults.bool(forKey: Key.snippets)
        syncsPortForwards = defaults.bool(forKey: Key.portForwards)
        syncsKnownHosts = defaults.bool(forKey: Key.knownHosts)
        syncsActivity = defaults.bool(forKey: Key.activity)
        syncsSettings = defaults.bool(forKey: Key.settings)
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAMIO_SYNC_LOCAL"] != nil {
                transport = LocalTransport()
            } else {
                transport = CloudKeyValueTransport()
            }
        #else
            transport = CloudKeyValueTransport()
        #endif
        passphrase = store.readEncryptedDefault(from: .syncPassphrase, Secret(passphrase: ""))?.passphrase
        if let saved = store.readEncryptedDefault(from: .syncState, SyncState()) { state = saved }
    }

    /// Call once the app has launched: syncs, and from then on syncs after
    /// every change here or on another device.
    public func start() {
        guard !started else { return }
        started = true
        transport.changed = { [weak self] in
            guard let self else { return }
            if !adoptSharedPassphrase() {
                turnOnByDefault()
                sync()
            }
        }
        // Asks iCloud for what it has, well before Settings asks whether
        // there is anything.
        _ = transport.read()
        // Whatever sync carries, changed here.
        let changes = Publishers.MergeMany(
            store.$machineGroup.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$identityGroup.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$snippetGroup.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$portForwardGroup.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: KnownHosts.didChange).map { _ in () }.eraseToAnyPublisher(),
            AgentServer.shared.log.$entries.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            // Every preference ends up in the defaults, whoever keeps it.
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .filter { [weak self] _ in
                    MainActor.assumeIsolated { self?.preferencesChanged() ?? false }
                }
                .map { _ in () }
                .eraseToAnyPublisher()
        )
        .share()
        changes
            .sink { [weak self] in
                // The generation count is only meaningful when every change is
                // published on the main thread; the store enforces that in
                // DEBUG builds, and this guard keeps RELEASE ones safe.
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { self?.generation += 1 }
            }
            .store(in: &observers)
        // The publishers fire before the value is set; by the time the delay
        // has passed the store has it.
        changes
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.sync() }
            }
            .store(in: &observers)
        #if canImport(UIKit)
            let becameActive = UIApplication.didBecomeActiveNotification
        #else
            let becameActive = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.publisher(for: becameActive)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
            .store(in: &observers)
        #if DEBUG
            // TAMIO_SYNC_LOCAL=<passphrase> also turns sync on.
            if let passphrase = ProcessInfo.processInfo.environment["TAMIO_SYNC_LOCAL"],
               passphrase.count >= Self.minimumPassphraseLength
            {
                turnOn(passphrase: passphrase)
                return
            }
        #endif
        if adoptSharedPassphrase() { return }
        turnOnByDefault()
        sync()
    }

    /// How long a first launch waits for iCloud to deliver what another
    /// device stored, before making a passphrase of its own.
    static let firstSyncWait: UInt64 = 15_000_000_000

    /// Sync is on unless the user turned it off here. With a passphrase shared
    /// in iCloud Keychain it uses that one; when iCloud holds data under one
    /// that has not arrived, it waits for it; else it makes one, after giving
    /// iCloud time to deliver another device's.
    private func turnOnByDefault() {
        guard !isOn, problem == nil, !defaults.bool(forKey: Key.optedOut) else { return }
        if let shared = SyncKeychain.read(), !shared.isEmpty {
            turnOn(passphrase: shared)
            return
        }
        if hasStoredData {
            // On, and locked until the passphrase arrives or is entered.
            isOn = true
            defaults.set(true, forKey: Key.on)
            status = .locked
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.firstSyncWait)
            guard let self, !isOn, problem == nil, !defaults.bool(forKey: Key.optedOut) else { return }
            if adoptSharedPassphrase() { return }
            if let shared = SyncKeychain.read(), !shared.isEmpty {
                turnOn(passphrase: shared)
            } else if hasStoredData {
                turnOnByDefault()
            } else {
                turnOn(passphrase: Self.makePassphrase())
            }
        }
    }

    /// Six groups of four letters and digits, none easily mistaken for
    /// another: about 150 bits.
    static func makePassphrase() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var generator = SystemRandomNumberGenerator()
        return (0 ..< 6).map { _ in
            String((0 ..< 4).map { _ in alphabet[Int.random(in: 0 ..< alphabet.count, using: &generator)] })
        }.joined(separator: "-")
    }

    /// The passphrase in use here, for the user to type on a device without
    /// iCloud Keychain.
    public var currentPassphrase: String? { passphrase }

    /// Turns sync on with the passphrase another device shared in iCloud
    /// Keychain, when iCloud holds data and the user has not turned sync off
    /// here. True when it did.
    @discardableResult
    private func adoptSharedPassphrase() -> Bool {
        guard !isOn, problem == nil, !defaults.bool(forKey: Key.optedOut),
              hasStoredData, let shared = SyncKeychain.read(), !shared.isEmpty
        else { return false }
        turnOn(passphrase: shared)
        return true
    }

    // MARK: - Settings

    /// Turns sync on, or gives this device the passphrase again after it was
    /// refused.
    public func turnOn(passphrase new: String) {
        guard problem == nil else { return }
        defaults.set(false, forKey: Key.optedOut)
        set(passphrase: new)
        if !isOn {
            state = SyncState()
            isOn = true
            defaults.set(true, forKey: Key.on)
            generation += 1
            if !hasStoredData {
                // iCloud may not have delivered what another device stored
                // yet; give it a moment before storing over it.
                status = .syncing
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.sync()
                }
                return
            }
        }
        sync()
    }

    /// Stops syncing here. What is in iCloud, and on this device, stays.
    public func turnOff() {
        isOn = false
        defaults.set(false, forKey: Key.on)
        defaults.set(true, forKey: Key.optedOut)
        passphrase = nil
        key = nil
        store.removeDefault(.syncPassphrase)
        state = SyncState()
        store.removeDefault(.syncState)
        generation += 1
        status = .off
    }

    /// Puts this device's data in place of what is in iCloud, sealed under
    /// `passphrase` (or the current one). Other devices are then asked for it.
    public func replaceStoredData(passphrase new: String? = nil) {
        guard isOn else { return }
        if let new {
            // The key in use until now is kept for the round: it reads what
            // is stored one last time.
            let old = key
            set(passphrase: new)
            key = old
        }
        replacesNext = true
        sync()
    }

    /// Removes what is in iCloud and stops syncing here. A device that still
    /// syncs will store its data again.
    public func deleteStoredData() {
        do {
            try transport.write(nil)
        } catch {
            debugPrint("CloudSync: failed to delete stored data: \(error.localizedDescription)")
            // Staying on, with the failure showing: turning off would say
            // the data is gone when it is not.
            status = .failed(String(localized: "The data in iCloud could not be removed: \(error.localizedDescription)"))
            return
        }
        SyncKeychain.delete()
        turnOff()
    }

    private func set(passphrase new: String) {
        passphrase = new
        key = nil
        store.storeEncryptedDefault(to: .syncPassphrase, with: Secret(passphrase: new))
        // The user's other devices find it in iCloud Keychain.
        SyncKeychain.save(new)
    }

    // MARK: - Sync

    public func sync() {
        guard isOn else {
            status = .off
            return
        }
        if let problem {
            status = .unavailable(problem)
            return
        }
        if passphrase?.isEmpty ?? true, let shared = SyncKeychain.read(), !shared.isEmpty {
            set(passphrase: shared)
        }
        guard let passphrase, !passphrase.isEmpty else {
            status = .locked
            return
        }
        if running {
            pending = true
            return
        }
        running = true
        if case .synced = status {} else { status = .syncing }

        var input = SyncInput(
            machines: store.machineGroup.machines,
            identities: store.identityGroup.identities,
            state: state,
            passphrase: passphrase,
            remote: transport.read(),
            key: key
        )
        input.snippets = store.snippetGroup.snippets
        input.portForwards = store.portForwardGroup.forwards
        input.knownHosts = KnownHosts.shared.syncEntries()
        input.preferences = readPreferences()
        input.preferenceKeys = Set(preferences.map(\.key))
        input.activity = AgentServer.shared.log.entries
        input.activityClearedAt = AgentServer.shared.log.clearedAt
        input.syncsMachines = syncsServers
        input.syncsIdentities = syncsIdentities
        input.syncsSnippets = syncsSnippets
        input.syncsPortForwards = syncsPortForwards
        input.syncsKnownHosts = syncsKnownHosts
        input.syncsPreferences = syncsSettings
        input.syncsActivity = syncsActivity
        input.replacesRemote = replacesNext
        replacesNext = false

        let round = input
        let read = generation
        Task {
            // Deriving a key takes a few hundred milliseconds.
            let outcome = await Task.detached(priority: .utility) { SyncSession.run(round) }.value
            if read == generation {
                finish(outcome)
            } else {
                // Something was edited meanwhile: what the round worked out
                // is about data that is gone.
                replacesNext = replacesNext || round.replacesRemote
                pending = true
            }
            running = false
            if pending {
                pending = false
                sync()
            }
        }
    }

    private func readPreferences() -> [PreferenceItem] {
        preferences.compactMap { preference in
            preference.read().map { PreferenceItem(key: preference.key, value: $0) }
        }
    }

    /// True when a synced preference changed since it was last read.
    private func preferencesChanged() -> Bool {
        let values = readPreferences()
        guard values != preferenceValues else { return false }
        preferenceValues = values
        return true
    }

    private func finish(_ outcome: SyncOutcome) {
        guard isOn else { return }
        switch outcome {
        case .locked:
            // Changed on another device, which shared the new one.
            if let shared = SyncKeychain.read(), !shared.isEmpty, shared != passphrase {
                set(passphrase: shared)
                sync()
                return
            }
            status = .locked
        case .unreadable:
            status = .unreadable
        case .newer:
            status = .failed(String(localized: "What is in iCloud was written by a newer version of Tamio. Update Tamio on this device."))
        case let .done(done):
            key = done.key
            if !done.machines.isEmpty {
                var group = store.machineGroup
                for change in done.machines {
                    switch change {
                    case let .put(machine): group.insert(machine)
                    case let .remove(id): group.delete(id)
                    }
                }
                store.machineGroup = group
            }
            if !done.identities.isEmpty {
                var group = store.identityGroup
                for change in done.identities {
                    switch change {
                    case let .put(identity): group.insert(identity)
                    case let .remove(id): group.delete(id)
                    }
                }
                store.identityGroup = group
            }
            if !done.snippets.isEmpty {
                var group = store.snippetGroup
                for change in done.snippets {
                    switch change {
                    case let .put(snippet): group.insert(snippet)
                    case let .remove(id): group.delete(id)
                    }
                }
                store.snippetGroup = group
            }
            if !done.portForwards.isEmpty {
                var group = store.portForwardGroup
                for change in done.portForwards {
                    switch change {
                    case let .put(forward): group.insert(forward)
                    case let .remove(id): group.delete(id)
                    }
                }
                store.portForwardGroup = group
            }
            if !done.knownHosts.isEmpty {
                var put: [KnownHostEntry] = []
                var removed: [UUID] = []
                for change in done.knownHosts {
                    switch change {
                    case let .put(entry): put.append(entry)
                    case let .remove(id): removed.append(id)
                    }
                }
                KnownHosts.shared.applySynced(put: put, remove: removed)
            }
            for change in done.preferences {
                // A preference reset elsewhere keeps its value here: a
                // device with no value has nothing better to offer.
                guard case let .put(item) = change,
                      let preference = preferences.first(where: { $0.key == item.key })
                else { continue }
                preference.write(item.value)
            }
            if !done.preferences.isEmpty { preferenceValues = readPreferences() }
            // Another device's activity is added, not recorded: it is not
            // sent on as this device's own.
            for entry in done.activity { AgentServer.shared.log.merge(entry) }
            state = done.state
            if let upload = done.upload {
                do {
                    try transport.write(upload)
                } catch {
                    status = .failed(error.localizedDescription)
                    return
                }
            }
            status = .synced(Date())
        }
    }
}
