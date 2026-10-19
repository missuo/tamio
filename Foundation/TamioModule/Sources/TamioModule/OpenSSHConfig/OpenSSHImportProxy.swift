import Foundation

/// The networking engine expands %h, %p and %% once, then invokes /bin/sh.
/// Generated commands contain only shell-quoted literal arguments; escaping %
/// happens after quoting so neither expansion layer can reinterpret config data.
enum OpenSSHImportProxy {
    static func jumpCommand(_ value: String, source: String, host: String, port: String) throws -> String {
        let jumps = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !jumps.isEmpty, jumps.count <= 32, safeHost(host), !source.contains("\0") else {
            throw OpenSSHImportError(String(localized: "The proxy jump cannot be represented safely."))
        }
        for jump in jumps { try validateJump(jump) }
        let destination = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(port)" : "\(host):\(port)"
        var arguments = ["/usr/bin/ssh", "-F", source, "-W", destination]
        if jumps.count > 1 { arguments += ["-J", jumps.dropLast().joined(separator: ",")] }
        // -l and -p are explicit so IPv6 and a jump user's name never become
        // ambiguous positional syntax. -- protects the final destination.
        let last = try parseJump(jumps[jumps.count - 1])
        if let user = last.user { arguments += ["-l", user] }
        if let port = last.port { arguments += ["-p", port] }
        arguments += ["--", last.host]
        return arguments.map(quote).joined(separator: " ").replacingOccurrences(of: "%", with: "%%")
    }

    static func validateCommand(_ command: String, host: String) throws {
        guard safeHost(host), !command.contains("\0"), !command.contains("\n"), !command.contains("\r") else {
            throw OpenSSHImportError(String(localized: "The proxy command cannot be represented safely."))
        }
        var characters = command.makeIterator()
        while let character = characters.next() {
            if character == "%" {
                guard let token = characters.next(), token == "h" || token == "p" || token == "%" else {
                    throw OpenSSHImportError(String(localized: "This proxy command uses tokens Tamio does not support. Only %h, %p and %% are supported."))
                }
            }
        }
    }

    static func safeHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_:[]").contains($0)
        }
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validateJump(_ value: String) throws { _ = try parseJump(value) }

    private static func parseJump(_ value: String) throws -> (user: String?, host: String, port: String?) {
        func invalid() -> OpenSSHImportError { OpenSSHImportError(String(localized: "The proxy jump has an unsupported host, user or port.")) }
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }), !value.contains("%") else { throw invalid() }
        let userParts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard userParts.count <= 2 else { throw invalid() }
        let user = userParts.count == 2 ? String(userParts[0]) : nil
        if let user {
            guard !user.isEmpty, !user.hasPrefix("-"), user.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-").contains($0)
            }) else { throw invalid() }
        }
        let address = String(userParts.last ?? "")
        var host: String
        var port: String?
        if address.hasPrefix("[") {
            guard let end = address.firstIndex(of: "]") else { throw invalid() }
            host = String(address[address.index(after: address.startIndex)..<end])
            guard host.contains(":"), !host.contains("["), !host.contains("]") else { throw invalid() }
            let suffix = address[address.index(after: end)...]
            if !suffix.isEmpty {
                guard suffix.hasPrefix(":") else { throw invalid() }
                port = String(suffix.dropFirst())
            }
        } else {
            let parts = address.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw invalid() }
            host = String(parts[0])
            if parts.count == 2 { port = String(parts[1]) }
        }
        guard safeHost(host), !host.contains("["), !host.contains("]") else { throw invalid() }
        if let port {
            guard port.allSatisfy(\.isNumber), let number = Int(port), (1 ... 65535).contains(number) else { throw invalid() }
        }
        return (user, host, port)
    }
}
