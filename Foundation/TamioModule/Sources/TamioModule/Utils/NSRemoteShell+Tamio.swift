//
//  NSRemoteShell+Tamio.swift
//  TamioModule
//
//  Shared shell scaffolding, previously copy-pasted across both apps.
//

import Foundation
import NSRemoteShell

public extension NSRemoteShell {
    /// Returns a shell preconfigured with the machine's address and port.
    /// An unparsable port keeps the historical 0 value, which simply fails
    /// to connect and surfaces through the usual error path.
    @discardableResult
    static func configured(for machine: RDMachine, timeout: NSNumber) -> NSRemoteShell {
        configured(host: machine.remoteAddress, port: machine.remotePort, timeout: timeout)
            .setupProxyCommand(machine.proxyCommand)
    }

    /// Returns a shell preconfigured with the given address and port string.
    @discardableResult
    static func configured(host: String, port: String, timeout: NSNumber) -> NSRemoteShell {
        NSRemoteShell().applyConnection(host: host, port: port, timeout: timeout)
    }

    /// Applies connection parameters to an existing shell, returning self for chaining.
    @discardableResult
    func applyConnection(host: String, port: String, timeout: NSNumber) -> NSRemoteShell {
        KnownHosts.install()
        return setupConnectionHost(host)
            .setupConnectionPort(NSNumber(value: Int(port) ?? 0))
            .setupConnectionTimeout(timeout)
    }

    /// Applies the machine's connection parameters to an existing shell.
    @discardableResult
    func applyConnection(for machine: RDMachine, timeout: NSNumber) -> NSRemoteShell {
        applyConnection(host: machine.remoteAddress, port: machine.remotePort, timeout: timeout)
            .setupProxyCommand(machine.proxyCommand)
    }

    /// Tries each identity in order as the server's user, reconnecting when
    /// the user changes (a server saved before servers had a user signs in as
    /// each identity's own; the remote side authenticates per connection).
    /// Returns true when the shell ends up authenticated.
    @discardableResult
    func authenticateWithAutoIdentities(
        _ identities: [RDIdentity],
        for machine: RDMachine,
        hint: ((String) -> Void)? = nil
    ) -> Bool {
        var previousUsername: String?
        for identity in identities {
            let username = machine.loginUsername(with: identity)
            guard !username.isEmpty else { continue }
            hint?("[i] trying to authenticate as \(username) with \(identity.displayName)")
            if let prev = previousUsername, prev != username {
                requestDisconnectAndWait()
                requestConnectAndWait()
            }
            previousUsername = username
            identity.callAuthenticationWith(remote: self, username: username)
            if isConnected, isAuthenticated {
                break
            }
        }
        return isConnected && isAuthenticated
    }

    /// Outcome of `connectAndAuthenticate`.
    enum ConnectAndAuthenticateResult {
        /// Connected and authenticated.
        case success
        /// The initial connection failed.
        case connectFailed
        /// Connected, but authentication failed.
        case authenticateFailed
    }

    /// Connects (blocking), then authenticates with `identity` when given,
    /// otherwise with each of `autoIdentities` in turn. Shared by the
    /// terminal, file-transfer and monitor bootstraps of both apps.
    @discardableResult
    func connectAndAuthenticate(
        identity: RDIdentity?,
        autoIdentities: [RDIdentity],
        for machine: RDMachine,
        hint: ((String) -> Void)? = nil
    ) -> ConnectAndAuthenticateResult {
        KnownHosts.install()
        requestConnectAndWait()
        guard isConnected else { return .connectFailed }
        if let identity {
            identity.callAuthenticationWith(remote: self, username: machine.loginUsername(with: identity))
        } else {
            authenticateWithAutoIdentities(autoIdentities, for: machine, hint: hint)
        }
        return isConnected && isAuthenticated ? .success : .authenticateFailed
    }
}
