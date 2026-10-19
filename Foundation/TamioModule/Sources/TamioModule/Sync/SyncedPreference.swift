//
//  SyncedPreference.swift
//  TamioModule
//
//  The preferences in Settings that are the same on every device. They live
//  in modules this one cannot see (the terminal's configuration, the app's
//  appearance), so the app hands each one over with how to read it and how
//  to put in place a value that arrived.
//

import CryptoKit
import Foundation

public struct SyncedPreference {
    public enum Value: Codable, Equatable, Sendable {
        case bool(Bool)
        case int(Int)
        case string(String)
        case data(Data)
    }

    /// The same on every device, and never changed: it names the preference
    /// in iCloud.
    public let key: String
    let read: @MainActor () -> Value?
    let write: @MainActor (Value) -> Void

    /// `read` gives the value in effect here, nil when there is none to share.
    /// `write` puts in place a value from another device and applies it.
    public init(
        _ key: String,
        read: @escaping @MainActor () -> Value?,
        write: @escaping @MainActor (Value) -> Void
    ) {
        self.key = key
        self.read = read
        self.write = write
    }

    public static func bool(_ key: String, get: @escaping @MainActor () -> Bool, set: @escaping @MainActor (Bool) -> Void) -> Self {
        Self(key, read: { .bool(get()) }, write: { if case let .bool(value) = $0 { set(value) } })
    }

    public static func int(_ key: String, get: @escaping @MainActor () -> Int, set: @escaping @MainActor (Int) -> Void) -> Self {
        Self(key, read: { .int(get()) }, write: { if case let .int(value) = $0 { set(value) } })
    }

    public static func string(_ key: String, get: @escaping @MainActor () -> String, set: @escaping @MainActor (String) -> Void) -> Self {
        Self(key, read: { .string(get()) }, write: { if case let .string(value) = $0 { set(value) } })
    }
}

/// One preference as sync carries it.
struct PreferenceItem: SyncItem, Equatable {
    var id: UUID
    var key: String
    var value: SyncedPreference.Value

    init(key: String, value: SyncedPreference.Value) {
        id = Self.id(for: key)
        self.key = key
        self.value = value
    }

    var content: PreferenceItem { self }
    func arriving(over _: PreferenceItem?) -> PreferenceItem { self }

    /// Made from the key, so a preference is the same item on every device.
    static func id(for key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("preference:\(key)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: bytes.withUnsafeBytes { $0.load(as: uuid_t.self) })
    }
}
