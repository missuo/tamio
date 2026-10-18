//
//  RDMachine.swift
//  Tamio
//
//  Created by Lakr Aream on 2022/2/8.
//

import Foundation

public struct RDMachine: Codable, Identifiable, Equatable, Sendable {
    public init(id: UUID = UUID(),
                remoteAddress: String = "",
                remotePort: String = "",
                name: String = "",
                group: String = "",
                lastConnection: Date = .init(),
                lastBanner: String = "",
                comment: String = "",
                associatedIdentity: String? = nil,
                attachment: [String: String] = [:])
    {
        self.id = id
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.name = name
        self.group = group
        self.lastConnection = lastConnection
        self.lastBanner = lastBanner
        self.comment = comment
        self.associatedIdentity = associatedIdentity
        self.attachment = attachment
    }

    public var id = UUID()

    // generic authenticate filed required for ssh
    public var remoteAddress: String
    public var remotePort: String

    // application required
    public var name: String
    public var group: String
    public var lastConnection: Date
    public var lastBanner: String
    public var comment: String
    public var associatedIdentity: String?

    // reserved for future use
    public var attachment: [String: String]

    /// Where Files opens on this server; empty for the user's home folder.
    public var fileTransferLoginPath: String {
        get {
            attachment["sftp.login.path", default: ""]
        }
        set {
            attachment["sftp.login.path"] = newValue
        }
    }

    /// Files opens in the home folder of the user it signs in as. "/" was
    /// the default once and was saved with servers nobody chose it for, so
    /// it means the home folder too.
    public var startsInHomeFolder: Bool {
        let path = fileTransferLoginPath.trimmingCharacters(in: .whitespaces)
        return path.isEmpty || path == "/"
    }

    /// The user to sign in as. The identity only says how (password or key).
    public var username: String {
        get { attachment["username"] ?? "" }
        set { attachment["username"] = newValue.isEmpty ? nil : newValue }
    }

    /// The user a server signs in as when none is set.
    public static let defaultUsername = "root"

    /// The server's user; for a server saved before servers had one, the user
    /// its identity was made for; else root.
    public func loginUsername(with identity: RDIdentity?) -> String {
        if !username.isEmpty { return username }
        if let legacy = identity?.username, !legacy.isEmpty { return legacy }
        return Self.defaultUsername
    }

    /// Free-form labels ("prod", "tokyo") for search and filtering.
    public var tags: [String] {
        get {
            (attachment["tags"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            let joined = newValue
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: " ") }
                .filter { !$0.isEmpty }
                .joined(separator: ",")
            attachment["tags"] = joined.isEmpty ? nil : joined
        }
    }

    /// A snippet typed into the terminal once it has signed in.
    public var startupSnippet: RDSnippet.ID? {
        get { attachment["startup.snippet"].flatMap(UUID.init(uuidString:)) }
        set { attachment["startup.snippet"] = newValue?.uuidString }
    }

    /// A command whose stdin and stdout carry the connection, instead of a
    /// direct TCP connection: `cloudflared access ssh --hostname %h`. `%h` is
    /// the address and `%p` the port, as OpenSSH writes them. Empty connects
    /// directly.
    public var proxyCommand: String {
        get { attachment["proxy.command"] ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            attachment["proxy.command"] = trimmed.isEmpty ? nil : trimmed
        }
    }

    // convince

    public func isQualifiedForSearch(text: String) -> Bool {
        let searchText = text.lowercased()
        if remoteAddress.description.lowercased().contains(searchText) { return true }
        if remotePort.description.lowercased().contains(searchText) { return true }
        if name.description.lowercased().contains(searchText) { return true }
        if group.description.lowercased().contains(searchText) { return true }
        if lastBanner.description.lowercased().contains(searchText) { return true }
        if comment.description.lowercased().contains(searchText) { return true }
        if tags.contains(where: { $0.lowercased().contains(searchText) }) { return true }
        if proxyCommand.lowercased().contains(searchText) { return true }
        return false
    }

    public func shortDescription(withComment: Bool = true) -> String {
        var build = name + " "
        let identity = associatedIdentity.flatMap(UUID.init(uuidString:)).map { TamioStore.shared.identityGroup[$0] }
        let user = loginUsername(with: identity)
        if !user.isEmpty {
            build += user + "@"
        }
        build += remoteAddress
        if remotePort != "22" {
            build += " -p " + remotePort
        }
        if withComment, !comment.isEmpty {
            build += " (" + comment + ")"
        }
        return build
    }

    public func isNotPlaceholder() -> Bool {
        remoteAddress.count > 0 && remotePort.count > 0
    }

    public func getCommand(insertLeadingSSH: Bool = true) -> String {
        var build = ""
        let leading = insertLeadingSSH ? "ssh " : ""
        let identity = associatedIdentity.flatMap(UUID.init(uuidString:)).map { TamioStore.shared.identityGroup[$0] }
        let user = loginUsername(with: identity)
        if !user.isEmpty {
            build = leading + "\(user)@\(remoteAddress)"
        }
        if build.isEmpty {
            build = leading + "\(remoteAddress)"
        }
        if remotePort != "22" {
            build += " -p " + remotePort
        }
        if !proxyCommand.isEmpty {
            build += " -o ProxyCommand=\"" + proxyCommand.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return build
    }
}

extension RDMachine: RDGroupItem, RDGroupSectionedItem {
    public init() { self.init(id: UUID()) }
}
