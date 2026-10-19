import Foundation

public enum OpenSSHImportStatus: String, Sendable {
    case ready, needsCredentials, needsReview, alreadyExists, unsupported
}

public struct OpenSSHImportCandidate: Identifiable, Sendable {
    public var id: String { host.candidate.alias }
    public let host: OpenSSHResolvedHost
    public var machine: RDMachine
    public let existing: RDMachine?
    public let identityFiles: [String]
    public let diagnostics: [String]
    public let status: OpenSSHImportStatus
    public let canImport: Bool
}

public enum OpenSSHCredentialChoice: Sendable, Equatable {
    case none
    case existing(UUID)
    case importFile(String, passphrase: String)
}

public struct OpenSSHImportSelection: Sendable {
    public let alias: String
    public let credential: OpenSSHCredentialChoice
    public let replaceExisting: Bool
    public let acknowledgeWarnings: Bool

    public init(alias: String, credential: OpenSSHCredentialChoice, replaceExisting: Bool = false, acknowledgeWarnings: Bool = false) {
        self.alias = alias
        self.credential = credential
        self.replaceExisting = replaceExisting
        self.acknowledgeWarnings = acknowledgeWarnings
    }
}

public struct OpenSSHImportBatch: Sendable {
    public let machines: [RDMachine]
    public let identities: [RDIdentity]
    public let created: Int
    public let updated: Int
}

public enum OpenSSHImportPlanner {
    static let sourceKey = "openssh.config.path"
    static let aliasKey = "openssh.config.alias"

    public static func plan(scan: OpenSSHScan, resolved: [OpenSSHResolvedHost], machines: [RDMachine], identities: [RDIdentity]) -> [OpenSSHImportCandidate] {
        let source = OpenSSHImportCredentials.canonicalPath(scan.sourcePath)
        return resolved.map { host in
            let options = host.options
            func value(_ key: String) -> String? { options[key]?.first }
            func enabled(_ key: String) -> Bool {
                guard let text = value(key)?.lowercased() else { return false }
                return !["none", "no", "false", "0", ""].contains(text)
            }
            var diagnostics = scan.warnings
            var unsupported = false
            if let error = host.error { diagnostics.append(error); unsupported = true }
            let address = value("hostname") ?? ""
            let port = value("port") ?? "22"
            let username = value("user") ?? ""
            if !OpenSSHImportProxy.safeHost(address) || Int(port).map({ !(1 ... 65535).contains($0) }) != false || username.isEmpty || username.contains(where: { $0.isNewline || $0 == "\0" }) {
                diagnostics.append(String(localized: "OpenSSH did not resolve a valid host, port and user."))
                unsupported = true
            }
            let sameSource = machines.filter { $0.attachment[sourceKey] == source && $0.attachment[aliasKey] == host.candidate.alias }
            let conflicts = machines.filter { $0.name == host.candidate.alias }
            let matches = sameSource.isEmpty ? conflicts : sameSource
            let existing = matches.count == 1 ? matches[0] : nil
            if matches.count > 1 {
                diagnostics.append(String(localized: "Several saved servers match this host. Resolve the duplicates before importing."))
                unsupported = true
            }
            var machine = existing ?? RDMachine(name: host.candidate.alias)
            machine.remoteAddress = address
            machine.remotePort = port
            machine.username = username
            machine.attachment[sourceKey] = source
            machine.attachment[aliasKey] = host.candidate.alias
            machine.attachment["openssh.config.location"] = "\(host.candidate.source.path):\(host.candidate.source.line)"
            machine.proxyCommand = ""
            do {
                if enabled("proxyjump"), let jump = value("proxyjump") {
                    machine.proxyCommand = try OpenSSHImportProxy.jumpCommand(jump, source: source, host: address, port: port)
                } else if enabled("proxycommand"), let command = value("proxycommand") {
                    try OpenSSHImportProxy.validateCommand(command, host: address)
                    machine.proxyCommand = command
                }
            } catch {
                diagnostics.append(error.localizedDescription)
                unsupported = true
            }
            if !machine.proxyCommand.isEmpty {
                diagnostics.append(String(localized: "This proxy runs a local command when connecting. It depends on local OpenSSH configuration, programs and keys; jump-host trust is managed separately from Tamio."))
            }
            let paths = (options["identityfile"] ?? []).filter { $0.lowercased() != "none" }.map { path in
                expandIdentityPath(path, host: address, alias: host.candidate.alias, user: username, port: port)
            }
            let identityFiles = paths.compactMap { $0 }
            let missingPaths = identityFiles.filter { !FileManager.default.fileExists(atPath: $0) }
            if !missingPaths.isEmpty {
                let names = missingPaths.joined(separator: ", ")
                diagnostics.append(String(localized: "These identity files are missing on this Mac: \(names). Choose another credential or save a draft."))
            }
            if paths.contains(where: { $0 == nil }) {
                diagnostics.append(String(localized: "An identity path contains expansion tokens Tamio cannot resolve. Choose its private key explicitly."))
            }
            if identityFiles.count > 1 {
                diagnostics.append(String(localized: "OpenSSH lists multiple identity files. Choose one credential explicitly; Tamio does not try this list in order."))
            }
            if machine.associatedIdentity == nil, identityFiles.count == 1 {
                let matches = OpenSSHImportCredentials.matchingIdentities(paths: identityFiles, identities: identities)
                if matches.count == 1 { machine.associatedIdentity = matches[0].id.uuidString }
            }
            // OpenSSH prints $SSH_SK_PROVIDER even for ordinary software keys.
            // A configured provider matters only when explicitly requested.
            let customSecurityProvider = scan.directives.contains("securitykeyprovider") && enabled("securitykeyprovider") && value("securitykeyprovider") != "internal"
            if enabled("certificatefile") || enabled("pkcs11provider") || identityFiles.contains(where: { $0.hasSuffix("-cert.pub") || FileManager.default.fileExists(atPath: $0 + "-cert.pub") }) || customSecurityProvider {
                diagnostics.append(String(localized: "SSH certificates and hardware-backed security keys are not supported by Tamio's connection engine."))
                unsupported = true
            }
            if scan.directives.contains("match") {
                diagnostics.append(String(localized: "Match rules are resolved only for this import. Tamio does not reevaluate them when connecting."))
            }
            if scan.requiresTrust {
                diagnostics.append(String(localized: "This configuration requires trust and may run local commands. Resolved settings are a snapshot, not live OpenSSH rules."))
            }
            if enabled("identityagent") || enabled("forwardagent") || enabled("addkeystoagent") || scan.directives.contains("usekeychain") {
                diagnostics.append(String(localized: "Tamio does not use the OpenSSH agent, keychain integration or agent forwarding. Choose a stored credential or explicitly import a key."))
            }
            if ["localforward", "remoteforward", "dynamicforward", "forwardx11", "tunnel"].contains(where: { enabled($0) }) {
                diagnostics.append(String(localized: "OpenSSH port, X11 and tunnel forwarding settings are not imported."))
            }
            if enabled("remotecommand") || enabled("localcommand") && enabled("permitlocalcommand") {
                diagnostics.append(String(localized: "OpenSSH local and remote commands are not imported."))
            }
            // ssh -G emits defaults as well as explicit settings. Inspect the
            // scanner's directive names to avoid treating every default as a
            // deliberate policy while still diagnosing ignored user policy.
            let handled: Set<String> = ["host", "hostname", "port", "user", "include", "match", "identityfile", "proxycommand", "proxyjump", "certificatefile", "pkcs11provider", "securitykeyprovider", "identityagent", "forwardagent", "addkeystoagent", "usekeychain", "localforward", "remoteforward", "dynamicforward", "forwardx11", "forwardx11trusted", "tunnel", "remotecommand", "localcommand", "permitlocalcommand", "ignoreunknown"]
            let ignoredPresent = scan.directives.subtracting(handled).sorted()
            if !ignoredPresent.isEmpty {
                let names = ignoredPresent.joined(separator: ", ")
                diagnostics.append(String(localized: "Tamio uses its own connection and host-trust policy; these OpenSSH settings are not imported: \(names)."))
            }
            if enabled("proxyusefdpass") {
                diagnostics.append(String(localized: "Proxy commands that pass file descriptors are not supported."))
                unsupported = true
            }
            if existing != nil, sameSource.isEmpty {
                diagnostics.append(String(localized: "A saved server matches this alias but was not imported from this source. Updating it requires explicit permission."))
            }
            let hasCredentials = associatedIdentity(machine, identities: identities)?.hasCredentials == true
            if !hasCredentials {
                diagnostics.append(String(localized: "No credential is selected. You may explicitly save this server as a draft and choose credentials before connecting."))
            }
            let status: OpenSSHImportStatus
            if unsupported { status = .unsupported }
            else if existing != nil, machine == existing { status = .alreadyExists }
            else if !hasCredentials { status = .needsCredentials }
            else if !diagnostics.isEmpty || existing != nil { status = .needsReview }
            else { status = .ready }
            var seenDiagnostics = Set<String>()
            return OpenSSHImportCandidate(host: host, machine: machine, existing: existing, identityFiles: identityFiles,
                                          diagnostics: diagnostics.filter { seenDiagnostics.insert($0).inserted },
                                          status: status, canImport: !unsupported)
        }
    }

    /// Returns complete replacement arrays, after every selected row has passed
    /// validation. The caller commits both arrays without suspending and only if
    /// its store still matches the arrays supplied here.
    public static func prepare(candidates: [OpenSSHImportCandidate], selections: [OpenSSHImportSelection], machines: [RDMachine], identities: [RDIdentity]) throws -> OpenSSHImportBatch {
        var resultMachines = machines
        var resultIdentities = identities
        var seenAliases = Set<String>()
        var seenMachines = Set<UUID>()
        var created = 0
        var updated = 0
        for selection in selections {
            try Task.checkCancellation()
            let matches = candidates.filter { $0.id == selection.alias }
            guard seenAliases.insert(selection.alias).inserted, matches.count == 1, let candidate = matches.first, candidate.canImport else {
                throw OpenSSHImportError(String(localized: "The import selection is invalid. Review the configuration again."))
            }
            guard selection.acknowledgeWarnings || candidate.diagnostics.isEmpty && candidate.status != .needsCredentials else {
                throw OpenSSHImportError(String(localized: "Review and acknowledge this host's warnings before importing."))
            }
            var machine = candidate.machine
            if let existing = candidate.existing {
                guard selection.replaceExisting else { throw OpenSSHImportError(String(localized: "Updating a saved server requires explicit permission.")) }
                guard machines.first(where: { $0.id == existing.id }) == existing else {
                    throw OpenSSHImportError(String(localized: "A saved server changed during review. Review the import again."))
                }
                guard machine.id == existing.id else { throw OpenSSHImportError(String(localized: "The import selection is invalid. Review the configuration again.")) }
            } else if machines.contains(where: {
                $0.id == machine.id || $0.name == machine.name || ($0.attachment[sourceKey] == machine.attachment[sourceKey] && $0.attachment[aliasKey] == machine.attachment[aliasKey])
            }) {
                throw OpenSSHImportError(String(localized: "A matching server was added during review. Review the import again."))
            }
            guard seenMachines.insert(machine.id).inserted else {
                throw OpenSSHImportError(String(localized: "Two selected hosts would update the same saved server. Choose only one."))
            }
            switch selection.credential {
            case .none:
                guard selection.acknowledgeWarnings else {
                    throw OpenSSHImportError(String(localized: "Saving without credentials requires explicit acknowledgement."))
                }
                machine.associatedIdentity = nil
            case let .existing(id):
                guard let identity = identities.first(where: { $0.id == id }),
                      !identity.isPrivate || candidate.existing?.associatedIdentity == id.uuidString,
                      identity.hasCredentials else {
                    throw OpenSSHImportError(String(localized: "The selected identity is no longer available or has no credentials."))
                }
                machine.associatedIdentity = id.uuidString
            case let .importFile(path, passphrase):
                let identity = try OpenSSHImportCredentials.importKey(path: path, passphrase: passphrase, identities: resultIdentities)
                if !resultIdentities.contains(where: { $0.id == identity.id }) { resultIdentities.append(identity) }
                machine.associatedIdentity = identity.id.uuidString
            }
            if let index = resultMachines.firstIndex(where: { $0.id == machine.id }) {
                resultMachines[index] = machine
                updated += 1
            } else {
                resultMachines.append(machine)
                created += 1
            }
        }
        try Task.checkCancellation()
        return OpenSSHImportBatch(machines: resultMachines, identities: resultIdentities, created: created, updated: updated)
    }

    private static func associatedIdentity(_ machine: RDMachine, identities: [RDIdentity]) -> RDIdentity? {
        guard let id = machine.associatedIdentity.flatMap(UUID.init(uuidString:)) else { return nil }
        return identities.first { $0.id == id }
    }

    private static func expandIdentityPath(_ path: String, host: String, alias: String, user: String, port: String) -> String? {
        var result = ""
        var characters = path.makeIterator()
        while let character = characters.next() {
            if character == "%" {
                guard let token = characters.next() else { return nil }
                switch token {
                case "%": result.append("%")
                case "d": result += NSHomeDirectory()
                case "h": result += host
                case "n": result += alias
                case "r": result += user
                case "p": result += port
                case "u": result += NSUserName()
                default: return nil
                }
            } else { result.append(character) }
        }
        guard !result.contains("${"), !result.contains("\0") else { return nil }
        return OpenSSHImportCredentials.canonicalPath(result)
    }
}
