//
//  RDIdentity.swift
//  Tamio
//
//  Created by Lakr Aream on 2022/2/9.
//

import Foundation
import NSRemoteShell

public struct RDIdentity: Codable, Identifiable, Equatable, Sendable {
    public init(
        id: UUID = .init(),
        username: String = "",
        password: String = "",
        privateKey: String = "",
        publicKey: String = "",
        lastRecentUsed: Date = .init(),
        comment: String = "",
        group: String = "",
        authenticAutomatically: Bool = true,
        attachment: [String: String] = [:]
    ) {
        self.id = id
        self.username = username
        self.password = password
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.lastRecentUsed = lastRecentUsed
        self.comment = comment
        self.group = group
        self.authenticAutomatically = authenticAutomatically
        self.attachment = attachment
    }

    public var id = UUID()

    // generic authenticate filed required for ssh
    public var username: String
    public var password: String
    public var privateKey: String
    public var publicKey: String

    // application required
    public var lastRecentUsed: Date
    public var comment: String
    public var group: String
    public var authenticAutomatically: Bool

    // reserved for future use
    public var attachment: [String: String]

    public func shortDescription() -> String {
        guard username.count > 0 else {
            return String(localized: "Unknown Error")
        }
        var build = String(localized: "User \(username) with \(getKeyType())")
        if group.count > 0 {
            build += " " + String(localized: "Group<\(group)>")
        }
        if comment.count > 0 {
            build += " (\(comment))"
        }
        return build
    }

    public func getKeyType() -> String {
        if privateKey.count > 0, publicKey.count > 0 {
            if password.count > 0 {
                return String(localized: "Key Pair")
            } else {
                return String(localized: "Plain Key Pair")
            }
        } else if privateKey.count > 0 {
            if password.count > 0 {
                return String(localized: "Private Key")
            } else {
                return String(localized: "Plain Private Key")
            }
        } else if publicKey.count > 0 {
            return String(localized: "Unknown Key")
        } else if password.count > 0 {
            return String(localized: "Password")
        } else {
            return String(localized: "Username Only")
        }
    }

    /// Signs in as `username`, the server's, with this identity's password or
    /// key. An identity is only a credential; which user it signs in as is
    /// the server's business.
    public func callAuthenticationWith(remote: NSRemoteShell, username: String) {
        if remote.isAuthenticated { return }
        if privateKey.count > 0 || publicKey.count > 0 {
            remote.authenticate(with: username, andPublicKey: publicKey, andPrivateKey: privateKey, andPassword: password)
        } else {
            remote.authenticate(with: username, andPassword: password)
        }
        guard remote.isAuthenticated else {
            return
        }
        let date = Date()
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        fmt.timeStyle = .full
        debugPrint("Identity \(id) was used to authentic session at \(fmt.string(from: date))")
        onMainThread {
            TamioStore.shared.identityGroup[id].lastRecentUsed = date
        }
    }
}

public extension RDIdentity {
    /// What the identity is called in lists ("Deploy key", "Office password").
    /// Identities saved before names existed show the user they were made for.
    var name: String {
        get { attachment["name"] ?? username }
        set { attachment["name"] = newValue }
    }

    /// The name, or what the credential is when it has none.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? authDescription : trimmed
    }

    /// A password or a key to sign in with.
    var hasCredentials: Bool {
        !password.isEmpty || !privateKey.isEmpty
    }

    /// The credentials typed into one server's editor rather than chosen from
    /// Identities. Hidden from every identity list, never tried on other
    /// servers, and deleted with its server.
    var isPrivate: Bool {
        get { attachment["private"] == "1" }
        set { attachment["private"] = newValue ? "1" : nil }
    }

    /// "Key pair · ed25519", "Password" style description.
    var authDescription: String {
        if !privateKey.isEmpty {
            if let type = keyAlgorithm { return String(localized: "Key pair · \(type)") }
            return String(localized: "Key pair")
        }
        if !password.isEmpty { return String(localized: "Password") }
        return String(localized: "No credentials")
    }

    var keyAlgorithm: String? {
        RDIdentity.keyAlgorithm(publicKey: publicKey, privateKey: privateKey)
    }

    /// "ed25519", "rsa" or "ecdsa", read from the public key, else from the
    /// private key: PEM headers, or the key type inside an OpenSSH key.
    static func keyAlgorithm(publicKey: String, privateKey: String) -> String? {
        let markers = [("ssh-ed25519", "ed25519"), ("ecdsa-sha2", "ecdsa"), ("ssh-rsa", "rsa"), ("BEGIN RSA", "rsa"), ("BEGIN EC", "ecdsa")]
        for (marker, name) in markers where publicKey.contains(marker) { return name }
        for (marker, name) in markers where privateKey.contains(marker) { return name }
        // An OpenSSH private key (-----BEGIN OPENSSH PRIVATE KEY-----) is
        // base64; its public part names the key type in plain bytes.
        let body = privateKey
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        if let data = Data(base64Encoded: body), let text = String(data: data, encoding: .isoLatin1) {
            for (marker, name) in markers where text.contains(marker) { return name }
        }
        return nil
    }
}

extension RDIdentity: RDGroupItem {
    public init() { self.init(id: UUID()) }
}
