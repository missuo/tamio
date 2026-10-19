//
//  SyncDocument.swift
//  TamioModule
//
//  What is synced, and how two copies are brought together: item by item, the
//  later change wins, and a deletion is a change like any other. Agent
//  activity is a log, not items to edit: every device's entries are kept,
//  the latest of them, and nothing is deleted.
//

import CryptoKit
import Foundation

/// The document kept in iCloud. An entry without a value is a deleted item.
struct SyncDocument: Codable, Sendable {
    struct Entry<Value: Codable & Sendable>: Codable, Sendable {
        var modified: Date
        var value: Value?
    }

    var machines: [String: Entry<RDMachine>] = [:]
    var identities: [String: Entry<RDIdentity>] = [:]
    var snippets: [String: Entry<RDSnippet>] = [:]
    var portForwards: [String: Entry<RDPortForward>] = [:]
    var knownHosts: [String: Entry<KnownHostEntry>] = [:]
    /// Settings, by the id made from each one's key.
    var preferences: [String: Entry<PreferenceItem>] = [:]
    /// The latest agent activity of every device, oldest first.
    var activity: [AgentActivity] = []
}

extension SyncDocument {
    // A document from a version that synced fewer kinds has no entry for
    // the others.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machines = try container.decodeIfPresent([String: Entry<RDMachine>].self, forKey: .machines) ?? [:]
        identities = try container.decodeIfPresent([String: Entry<RDIdentity>].self, forKey: .identities) ?? [:]
        snippets = try container.decodeIfPresent([String: Entry<RDSnippet>].self, forKey: .snippets) ?? [:]
        portForwards = try container.decodeIfPresent([String: Entry<RDPortForward>].self, forKey: .portForwards) ?? [:]
        knownHosts = try container.decodeIfPresent([String: Entry<KnownHostEntry>].self, forKey: .knownHosts) ?? [:]
        preferences = try container.decodeIfPresent([String: Entry<PreferenceItem>].self, forKey: .preferences) ?? [:]
        activity = try container.decodeIfPresent([AgentActivity].self, forKey: .activity) ?? []
    }
}

/// What this device last knew of each item: enough to tell what has changed
/// here since, and when. Kept on the device, never uploaded.
struct SyncState: Codable, Sendable, Equatable {
    struct Stamp: Codable, Sendable, Equatable {
        /// Nil for an item that was deleted.
        var digest: String?
        var modified: Date
    }

    var machines: [String: Stamp] = [:]
    var identities: [String: Stamp] = [:]
    var snippets: [String: Stamp] = [:]
    var portForwards: [String: Stamp] = [:]
    var knownHosts: [String: Stamp] = [:]
    var preferences: [String: Stamp] = [:]
}

extension SyncState {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machines = try container.decodeIfPresent([String: Stamp].self, forKey: .machines) ?? [:]
        identities = try container.decodeIfPresent([String: Stamp].self, forKey: .identities) ?? [:]
        snippets = try container.decodeIfPresent([String: Stamp].self, forKey: .snippets) ?? [:]
        portForwards = try container.decodeIfPresent([String: Stamp].self, forKey: .portForwards) ?? [:]
        knownHosts = try container.decodeIfPresent([String: Stamp].self, forKey: .knownHosts) ?? [:]
        preferences = try container.decodeIfPresent([String: Stamp].self, forKey: .preferences) ?? [:]
    }
}

/// A change to make on this device.
enum SyncChange<Value: Sendable>: Sendable {
    case put(Value)
    case remove(UUID)
}

protocol SyncItem: Codable, Sendable, Identifiable where ID == UUID {
    /// The item without what every device keeps for itself (when it was last
    /// used here). Two items with the same content are the same item.
    var content: Self { get }
    /// This item as it came from another device, keeping what `local` has of
    /// its own.
    func arriving(over local: Self?) -> Self
}

extension RDMachine: SyncItem {
    var content: RDMachine {
        var copy = self
        copy.lastConnection = Date(timeIntervalSinceReferenceDate: 0)
        copy.lastBanner = ""
        return copy
    }

    func arriving(over local: RDMachine?) -> RDMachine {
        guard let local else { return self }
        var copy = self
        copy.lastConnection = local.lastConnection
        copy.lastBanner = local.lastBanner
        return copy
    }
}

extension RDIdentity: SyncItem {
    var content: RDIdentity {
        var copy = self
        copy.lastRecentUsed = Date(timeIntervalSinceReferenceDate: 0)
        return copy
    }

    func arriving(over local: RDIdentity?) -> RDIdentity {
        guard let local else { return self }
        var copy = self
        copy.lastRecentUsed = local.lastRecentUsed
        return copy
    }
}

extension RDSnippet: SyncItem {
    var content: RDSnippet { self }
    func arriving(over _: RDSnippet?) -> RDSnippet { self }
}

extension RDPortForward: SyncItem {
    var content: RDPortForward { self }
    func arriving(over _: RDPortForward?) -> RDPortForward { self }
}

extension KnownHostEntry: SyncItem {
    var content: KnownHostEntry { self }
    func arriving(over _: KnownHostEntry?) -> KnownHostEntry { self }
}

/// Agent activity in iCloud: the latest entries of every device, each with
/// the end of its output shortened, so the log stays small.
enum SyncActivity {
    static let limit = 200
    static let tailLimit = 600

    static func trimmed(_ entry: AgentActivity) -> AgentActivity {
        func shorten(_ results: [AgentActivity.Result]) -> [AgentActivity.Result] {
            results.map { result in
                var result = result
                if result.tail.count > tailLimit { result.tail = String(result.tail.suffix(tailLimit)) }
                return result
            }
        }
        var copy = entry
        copy.results = shorten(copy.results)
        copy.steps = copy.steps?.map { step in
            var step = step
            step.results = shorten(step.results)
            return step
        }
        return copy
    }

    /// The stored entries with this device's, the latest `limit`; and those
    /// of other devices this one lacks, apart from any from before it was
    /// last cleared.
    static func combine(
        local: [AgentActivity], remote: [AgentActivity], clearedAt: Date?
    ) -> (entries: [AgentActivity], arrived: [AgentActivity], dirty: Bool) {
        // A task's entry grows a step at a time: the copy changed last wins.
        var byID: [UUID: AgentActivity] = [:]
        for entry in remote { byID[entry.id] = entry }
        for entry in local.suffix(limit) where byID[entry.id].map({ entry.lastChange > $0.lastChange }) ?? true {
            byID[entry.id] = trimmed(entry)
        }
        let entries = Array(byID.values.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }.suffix(limit))
        let localChanges = Dictionary(local.map { ($0.id, $0.lastChange) }, uniquingKeysWith: { a, _ in a })
        let arrived = entries.filter { entry in
            guard entry.date > (clearedAt ?? .distantPast) else { return false }
            return localChanges[entry.id].map { entry.lastChange > $0 } ?? true
        }
        let dirty = entries.map { "\($0.id)\($0.lastChange.timeIntervalSince1970)" }
            != remote.map { "\($0.id)\($0.lastChange.timeIntervalSince1970)" }
        return (entries, arrived, dirty)
    }
}

enum SyncMerge {
    /// A deletion is remembered this long, so a device that was away learns of
    /// it instead of bringing the item back.
    static let tombstoneLifetime: TimeInterval = 180 * 24 * 3600

    struct Result<Value: SyncItem> {
        /// The document's entries after the merge.
        var entries: [String: SyncDocument.Entry<Value>]
        /// What to change on this device.
        var changes: [SyncChange<Value>] = []
        /// The entries differ from the remote ones and are to be uploaded.
        var dirty = false
    }

    static func digest<Value: SyncItem>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value.content)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func reconcile<Value: SyncItem>(
        local: [Value],
        state: inout [String: SyncState.Stamp],
        remote: [String: SyncDocument.Entry<Value>],
        now: Date
    ) -> Result<Value> {
        var items: [String: Value] = [:]
        for value in local { items[value.id.uuidString] = value }

        // What changed here since the last sync: edited or new items, and
        // items that are gone. A change is dated after the one it follows,
        // even if that one came from a device whose clock runs ahead.
        func date(after stamp: SyncState.Stamp?) -> Date {
            guard let stamp else { return now }
            return max(now, stamp.modified.addingTimeInterval(0.001))
        }
        for (id, value) in items {
            let digest = digest(value)
            guard let known = state[id] else {
                // Never synced from here (sync was just turned on): what is
                // stored stands. Only an item the store lacks is new.
                if remote[id] == nil { state[id] = .init(digest: digest, modified: now) }
                continue
            }
            if known.digest != digest {
                state[id] = .init(digest: digest, modified: date(after: known))
            }
        }
        for (id, stamp) in state where stamp.digest != nil && items[id] == nil {
            state[id] = .init(digest: nil, modified: date(after: stamp))
        }

        var result = Result(entries: remote)
        for id in Set(state.keys).union(remote.keys) {
            switch (state[id], remote[id]) {
            case (nil, nil):
                continue
            case let (mine?, nil):
                guard mine.digest != nil else {
                    // Deleted here and not stored: nothing left to say.
                    state[id] = nil
                    continue
                }
                result.entries[id] = .init(modified: mine.modified, value: items[id])
                result.dirty = true
            case let (mine, theirs?):
                let theirDigest = theirs.value.map(digest)
                guard let mine else {
                    adopt(theirs, id, theirDigest, &items, &state, &result)
                    continue
                }
                if theirDigest == mine.digest {
                    // The same content: the stored date stands.
                    state[id]?.modified = theirs.modified
                } else if theirs.modified > mine.modified
                    // Changed at the same instant on two devices: both must
                    // pick the same one.
                    || (theirs.modified == mine.modified && (theirDigest ?? "") > (mine.digest ?? ""))
                {
                    adopt(theirs, id, theirDigest, &items, &state, &result)
                } else {
                    result.entries[id] = .init(modified: mine.modified, value: items[id])
                    result.dirty = true
                }
            }
        }

        let expiry = now.addingTimeInterval(-tombstoneLifetime)
        for (id, entry) in result.entries where entry.value == nil && entry.modified < expiry {
            result.entries[id] = nil
            state[id] = nil
            result.dirty = true
        }
        return result
    }

    private static func adopt<Value: SyncItem>(
        _ theirs: SyncDocument.Entry<Value>,
        _ id: String,
        _ digest: String?,
        _ items: inout [String: Value],
        _ state: inout [String: SyncState.Stamp],
        _ result: inout Result<Value>
    ) {
        if let value = theirs.value {
            let arrived = value.arriving(over: items[id])
            items[id] = arrived
            result.changes.append(.put(arrived))
        } else if items[id] != nil, let uuid = UUID(uuidString: id) {
            items[id] = nil
            result.changes.append(.remove(uuid))
        }
        state[id] = .init(digest: digest, modified: theirs.modified)
    }
}
