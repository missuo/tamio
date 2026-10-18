//
//  AgentHost.swift
//  TamioModule
//
//  What an agent may know about a server. Built from RDMachine and its
//  identity's kind, with no field that could hold a secret: no password, no
//  key, no passphrase. Everything the MCP server returns about a host is one
//  of these.
//

import Foundation

public struct AgentHost: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var address: String
    public var port: Int
    public var username: String
    public var group: String
    public var tags: [String]
    public var comment: String
    /// "key", "password" or "none".
    public var auth: String
    /// The shared identity's name ("Deploy key"), nil for a password kept with the server.
    public var identity: String?
    /// "ed25519", "rsa", "ecdsa" for keys.
    public var keyType: String?
    public var lastConnected: String?
    /// The command the connection goes through, empty when it connects directly.
    public var proxyCommand: String

    /// Built on the main thread, from the store.
    @MainActor
    public init(_ machine: RDMachine) {
        let identity = TamioStore.shared.associatedIdentity(for: machine)
        id = machine.id.uuidString
        name = machine.name
        address = machine.remoteAddress
        port = Int(machine.remotePort) ?? 22
        username = machine.loginUsername(with: identity)
        group = machine.group
        tags = machine.tags
        comment = machine.comment
        if let identity {
            auth = identity.privateKey.isEmpty ? "password" : "key"
            self.identity = identity.isPrivate ? nil : identity.displayName
            keyType = identity.keyAlgorithm
        } else {
            auth = "none"
            self.identity = nil
            keyType = nil
        }
        lastConnected = machine.lastConnection.timeIntervalSince1970 > 0
            ? ISO8601DateFormatter().string(from: machine.lastConnection)
            : nil
        proxyCommand = machine.proxyCommand
    }

    /// One `Host` block of an ssh_config, with no key or password in it.
    public var sshConfigBlock: String {
        let alias = name
            .lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        var lines = ["Host \(alias.isEmpty ? address : alias)", "    HostName \(address)"]
        if port != 22 { lines.append("    Port \(port)") }
        lines.append("    User \(username)")
        if !proxyCommand.isEmpty { lines.append("    ProxyCommand \(proxyCommand)") }
        return lines.joined(separator: "\n")
    }
}
