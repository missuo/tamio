//
//  KnownHosts.swift
//  TamioModule
//
//  The host keys of the servers connected to so far. A server's key is saved
//  the first time it is seen; after that a connection to the same address is
//  only made when the server presents the same key, so someone answering in
//  the server's place is refused instead of being handed the password.
//

import CryptoKit
import Foundation
import NSRemoteShell

/// One saved key as sync carries it: the address and its key, under an id
/// made from the address, the same on every device.
public struct KnownHostEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let line: String

    public init(name: String, line: String) {
        id = Self.id(for: name)
        self.name = name
        self.line = line
    }

    static func id(for name: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("known-host:" + name).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

public final class KnownHosts: @unchecked Sendable {
    public struct HostKey: Equatable, Sendable {
        /// The algorithm as SSH names it, "ssh-ed25519" for one.
        public let type: String
        public let key: Data

        /// What `ssh-keygen -l` prints for the key.
        public var fingerprint: String {
            let digest = Data(SHA256.hash(data: key)).base64EncodedString()
            return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
        }
    }

    public static let shared = KnownHosts()

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()
    /// The keys refused since launch, to tell the user what was offered.
    private var refused: [String: HostKey] = [:]

    public init(defaults: UserDefaults = .standard, storageKey: String = "sb.moe.tamio.knownHosts") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    /// Has every connection of `NSRemoteShell` checked against the saved keys.
    public static func install() {
        _ = installed
    }

    private static let installed: Void = {
        NSRemoteShell.hostKeyVerifier = { host, port, type, key in
            KnownHosts.shared.accepts(HostKey(type: type, key: key), host: host, port: port.intValue)
        }
    }()

    /// True for the key saved for the address, and for the first key seen
    /// there, which is saved. False for any other key.
    public func accepts(_ offered: HostKey, host: String, port: Int) -> Bool {
        let name = Self.name(host: host, port: port)
        lock.lock()
        defer { lock.unlock() }
        var saved = entries()
        guard let line = saved[name] else {
            saved[name] = Self.line(for: offered)
            defaults.set(saved, forKey: storageKey)
        Self.announceChange()
            Self.announceChange()
            refused[name] = nil
            return true
        }
        if line == Self.line(for: offered) {
            refused[name] = nil
            return true
        }
        refused[name] = offered
        return false
    }

    public func savedKey(host: String, port: Int) -> HostKey? {
        lock.lock()
        defer { lock.unlock() }
        return entries()[Self.name(host: host, port: port)].flatMap(Self.hostKey(from:))
    }

    /// The key the address offered that was refused, if one was since launch.
    public func refusedKey(host: String, port: Int) -> HostKey? {
        lock.lock()
        defer { lock.unlock() }
        return refused[Self.name(host: host, port: port)]
    }

    /// The next key the address presents is saved as its key.
    public func forget(host: String, port: Int) {
        let name = Self.name(host: host, port: port)
        lock.lock()
        defer { lock.unlock() }
        var saved = entries()
        saved[name] = nil
        defaults.set(saved, forKey: storageKey)
        refused[name] = nil
    }

    public func forgetAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
        Self.announceChange()
        refused.removeAll()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries().count
    }

    /// Why a connection to the address was refused, when its host key was the
    /// reason; nil when it was not.
    public func refusalMessage(host: String, port: Int) -> String? {
        guard let offered = refusedKey(host: host, port: port) else { return nil }
        var lines = [String(localized: "The host key of \(host):\(port) has changed, so the connection was refused.")]
        if let saved = savedKey(host: host, port: port) {
            lines.append(String(localized: "Saved: \(saved.type) \(saved.fingerprint)"))
        }
        lines.append(String(localized: "Offered: \(offered.type) \(offered.fingerprint)"))
        lines.append(String(localized: "If the server was reinstalled or its keys were replaced, choose Forget Host Key for it and connect again. If not, something may be intercepting the connection."))
        return lines.joined(separator: "\n")
    }

    // MARK: Sync

    /// Posted when a key is saved or forgotten.
    public static let didChange = Notification.Name("sb.moe.tamio.knownHostsChanged")

    private static func announceChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    /// Every saved key, as sync carries it.
    public func syncEntries() -> [KnownHostEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries().map { KnownHostEntry(name: $0.key, line: $0.value) }
    }

    /// Keys saved or forgotten on another device.
    public func applySynced(put: [KnownHostEntry], remove: [UUID]) {
        guard !put.isEmpty || !remove.isEmpty else { return }
        lock.lock()
        var saved = entries()
        let removed = Set(remove)
        for name in saved.keys where removed.contains(KnownHostEntry.id(for: name)) { saved[name] = nil }
        for entry in put { saved[entry.name] = entry.line }
        defaults.set(saved, forKey: storageKey)
        lock.unlock()
    }

    private func entries() -> [String: String] {
        defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    /// `[host]:port`, as known_hosts writes an address with a port.
    static func name(host: String, port: Int) -> String {
        "[\(host.trimmingCharacters(in: .whitespaces).lowercased())]:\(port)"
    }

    private static func line(for key: HostKey) -> String {
        key.type + " " + key.key.base64EncodedString()
    }

    private static func hostKey(from line: String) -> HostKey? {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let key = Data(base64Encoded: String(parts[1])) else { return nil }
        return HostKey(type: String(parts[0]), key: key)
    }
}

public extension NSRemoteShell {
    /// Why the last connection was refused over the server's host key; nil
    /// when the host key was not the reason.
    var hostKeyRefusal: String? {
        KnownHosts.shared.refusalMessage(host: remoteHost, port: remotePort.intValue)
    }
}

public extension RDMachine {
    /// The next host key this server presents is saved as its key.
    func forgetHostKey() {
        KnownHosts.shared.forget(host: remoteAddress, port: Int(remotePort) ?? 0)
    }
}
