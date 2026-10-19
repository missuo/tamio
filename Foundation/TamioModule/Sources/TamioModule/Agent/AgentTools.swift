//
//  AgentTools.swift
//  TamioModule
//
//  The MCP tools. Reads answer at once; anything that changes the store,
//  starts a forward or runs a command waits for the user's approval. No tool
//  returns a password, a private key or a passphrase: identities come back
//  as AgentIdentity, servers as AgentHost.
//

import Foundation
import NSRemoteShell

/// An identity as an agent sees it: its public half only.
public struct AgentIdentity: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var group: String
    /// "key" or "password".
    public var kind: String
    public var keyType: String?
    public var publicKey: String?
    public var usedBy: [String]

    @MainActor
    init(_ identity: RDIdentity) {
        id = identity.id.uuidString
        name = identity.displayName
        group = identity.group
        kind = identity.privateKey.isEmpty ? "password" : "key"
        keyType = identity.keyAlgorithm
        publicKey = identity.publicKey.isEmpty ? nil : identity.publicKey
        usedBy = TamioStore.shared.machineGroup.machines
            .filter { $0.associatedIdentity == identity.id.uuidString }
            .map(\.name)
    }
}

struct AgentSnippet: Codable, Sendable {
    var id: String
    var name: String
    var group: String
    var code: String
    var comment: String

    init(_ snippet: RDSnippet) {
        id = snippet.id.uuidString
        name = snippet.name
        group = snippet.group
        code = snippet.code
        comment = snippet.comment
    }
}

struct AgentForward: Codable, Sendable {
    var id: String
    var host: String?
    /// "local": a port on this Mac reaches target through the server;
    /// "remote": a port on the server reaches target from this Mac.
    var direction: String
    var bindPort: Int
    var targetHost: String
    var targetPort: Int
    var running: Bool
}

enum AgentTools {
    // MARK: - Definitions

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }

    static let string: JSONValue = ["type": "string"]
    static let integer: JSONValue = ["type": "integer"]
    static let boolean: JSONValue = ["type": "boolean"]
    static let strings: JSONValue = ["type": "array", "items": ["type": "string"]]
    static func describe(_ type: JSONValue, _ text: String) -> JSONValue {
        guard case var .object(object) = type else { return type }
        object["description"] = .string(text)
        return .object(object)
    }

    static let targets: JSONValue = describe(schema([
        "hosts": describe(strings, "Server ids, names or addresses"),
        "group": describe(string, "Every server in this group"),
        "tag": describe(string, "Every server with this tag"),
        "all": describe(boolean, "Every server"),
    ]), "Which servers")

    static func tool(_ name: String, _ description: String, _ input: JSONValue, readOnly: Bool) -> JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": input,
            "annotations": ["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(name.hasPrefix("remove_"))],
        ]
    }

    static let hostFields: [String: JSONValue] = [
        "address": describe(string, "IP or hostname"),
        "port": describe(integer, "SSH port, 22 when left out"),
        "name": describe(string, "Label; the address when left out"),
        "username": describe(string, "User to sign in as; root when left out"),
        "group": string,
        "tags": strings,
        "comment": string,
        "identity": describe(string, "Id or name of an SSH key identity to sign in with"),
        "password": describe(string, "Password to sign in with, kept with this server. Write-only: never returned"),
        "proxy_command": describe(string, "A command the connection goes through instead of a direct TCP connection, as in ssh_config ProxyCommand. %h is the address and %p the port, e.g. \"cloudflared access ssh --hostname %h\". Empty connects directly"),
    ]

    /// The goal a call serves: every step with the same task is one entry
    /// in the server's history.
    static let task: JSONValue = describe(string, "Short name of the goal this step serves, e.g. \"Install nginx\". Use the same task for every step toward one goal (adding a repository, apt update, the install, its config): they are kept as one entry in the servers' history, so the next agent sees what was done")

    /// Tools that change something take a task.
    static func withTask(_ definition: JSONValue) -> JSONValue {
        guard case var .object(tool) = definition, tool["annotations"]?["readOnlyHint"] == .bool(false),
              case var .object(input) = tool["inputSchema"] ?? .null, case var .object(properties) = input["properties"] ?? .null
        else { return definition }
        properties["task"] = task
        input["properties"] = .object(properties)
        tool["inputSchema"] = .object(input)
        return .object(tool)
    }

    static let definitions: [JSONValue] = toolList.map(withTask)

    static let toolList: [JSONValue] = [
        tool("list_hosts", "Servers Tamio knows: address, port, user, group, tags, how they sign in. No secrets.",
             schema(["query": string, "group": string, "tag": string]), readOnly: true),
        tool("get_host", "One server, with its live status when Tamio has it.", schema(["host": describe(string, "Id, name or address")], required: ["host"]), readOnly: true),
        tool("get_metrics", "Live CPU, memory, disk, load, network, traffic and OS of servers.", schema(["hosts": strings]), readOnly: true),
        tool("export_ssh_config", "ssh_config Host blocks for servers (HostName, Port, User, ProxyCommand; no keys).", schema(["hosts": strings]), readOnly: true),
        tool("run_command", "Run a shell command on servers, signed in with Tamio's saved credentials. The user approves first. Returns each server's exit code and output.",
             schema(["targets": targets, "command": string, "sudo": describe(boolean, "Run with sudo -n"), "timeout": describe(integer, "Seconds per server, 300 by default"), "concurrency": describe(integer, "Servers at once, 8 by default")], required: ["targets", "command"]), readOnly: false),
        tool("run_snippet", "Run a saved snippet on servers, like run_command.", schema(["targets": targets, "snippet": describe(string, "Snippet id or name"), "sudo": boolean, "timeout": integer], required: ["targets", "snippet"]), readOnly: false),
        tool("add_host", "Add a server. Sign-in is a key identity, or a password kept with the server.", schema(hostFields, required: ["address"]), readOnly: false),
        tool("update_host", "Change a server; only the fields given change.", schema(hostFields.merging(["host": describe(string, "Id, name or address of the server")]) { $1 }, required: ["host"]), readOnly: false),
        tool("remove_host", "Remove a server from Tamio.", schema(["host": string], required: ["host"]), readOnly: false),
        tool("list_identities", "SSH key identities: name, key type, public key, the servers using them. Private keys are never returned.", schema([:]), readOnly: true),
        tool("add_identity", "Add an SSH key identity. generate: true makes a new Ed25519 key and returns its public key, to put in authorized_keys. Or give private_key (write-only, never returned).",
             schema(["name": string, "group": string, "generate": boolean, "private_key": describe(string, "Write-only"), "public_key": string, "passphrase": describe(string, "Write-only")], required: ["name"]), readOnly: false),
        tool("remove_identity", "Remove an identity; servers using it lose their sign-in.", schema(["identity": string], required: ["identity"]), readOnly: false),
        tool("list_snippets", "Saved snippets with their code.", schema(["query": string]), readOnly: true),
        tool("add_snippet", "Save a snippet.", schema(["name": string, "code": string, "group": string, "comment": string], required: ["name", "code"]), readOnly: false),
        tool("update_snippet", "Change a snippet; only the fields given change.", schema(["snippet": string, "name": string, "code": string, "group": string, "comment": string], required: ["snippet"]), readOnly: false),
        tool("remove_snippet", "Remove a snippet.", schema(["snippet": string], required: ["snippet"]), readOnly: false),
        tool("list_port_forwards", "Port forwards and whether they run.", schema([:]), readOnly: true),
        tool("add_port_forward", "Add a port forward through a server. direction local: a port on this Mac reaches target_host:target_port from the server; remote: a port on the server reaches it from this Mac.",
             schema(["host": string, "direction": ["type": "string", "enum": ["local", "remote"]], "bind_port": integer, "target_host": string, "target_port": integer, "start": boolean], required: ["host", "bind_port", "target_host", "target_port"]), readOnly: false),
        tool("start_port_forward", "Start a port forward.", schema(["forward": describe(string, "Port forward id")], required: ["forward"]), readOnly: false),
        tool("stop_port_forward", "Stop a port forward.", schema(["forward": string], required: ["forward"]), readOnly: false),
        tool("remove_port_forward", "Remove a port forward.", schema(["forward": string], required: ["forward"]), readOnly: false),
        tool("get_activity", "What agents did on servers, newest first, from every Mac of the user: runs and changes through Tamio, and what agents reported with log_activity. Read it before working on a server.",
             schema(["host": describe(string, "Id, name or address; every server when left out"), "limit": describe(integer, "50 by default")]), readOnly: true),
        tool("log_activity", "Record what you did on servers by other means than Tamio (your own ssh, scp, a deploy), so the user and later agents see it. Never include secrets.",
             schema(["hosts": describe(strings, "Server ids, names or addresses"), "summary": describe(string, "One line: what you did"), "details": describe(string, "What changed and why"), "commands": describe(strings, "The commands you ran")], required: ["hosts", "summary"]), readOnly: false),
    ]

    // MARK: - Calls

    @MainActor
    static func call(_ name: String, arguments a: JSONValue, server: AgentServer, client: String) async throws -> JSONValue {
        let store = TamioStore.shared
        switch name {
        case "list_hosts":
            return .from(server.hosts(matching: a))

        case "get_host":
            let machine = try server.machine(named: a["host"]?.string ?? "")
            var host = JSONValue.from(AgentHost(machine))
            if case var .object(object) = host {
                object["status"] = server.environment?.metrics(for: machine.id) ?? .null
                host = .object(object)
            }
            return host

        case "get_metrics":
            let names = a["hosts"]?.strings ?? []
            let machines = names.isEmpty ? store.machineGroup.machines : try names.map(server.machine(named:))
            return .object(Dictionary(machines.map { ($0.name, server.environment?.metrics(for: $0.id) ?? .null) }, uniquingKeysWith: { first, _ in first }))

        case "export_ssh_config":
            let names = a["hosts"]?.strings ?? []
            let machines = names.isEmpty ? store.machineGroup.machines : try names.map(server.machine(named:))
            return .string(machines.map { AgentHost($0).sshConfigBlock }.joined(separator: "\n\n"))

        case "run_command", "run_snippet":
            let machines = try server.targets(a)
            var command = a["command"]?.string ?? ""
            if name == "run_snippet" {
                command = try snippet(named: a["snippet"]?.string ?? "").code
            }
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentToolError(String(localized: "The command is empty.")) }
            let sudo = a["sudo"]?.bool ?? false
            let count = machines.count
            let title = count == 1
                ? (sudo ? String(localized: "Run on 1 server with sudo") : String(localized: "Run on 1 server"))
                : (sudo ? String(localized: "Run on \(count) servers with sudo") : String(localized: "Run on \(count) servers"))
            try await server.requireApproval(AgentRequest(
                client: client, tool: name,
                title: title,
                detail: command, hosts: machines.map(\.name), hostIDs: machines.map(\.id.uuidString)
            ))
            let results = await AgentRunner.run(
                command: command, on: machines, sudo: sudo,
                timeout: Double(a["timeout"]?.int ?? 300), concurrency: a["concurrency"]?.int ?? 8
            )
            return .from(results)

        case "add_host", "update_host":
            let existing = name == "update_host" ? try server.machine(named: a["host"]?.string ?? "") : nil
            var machine = existing ?? RDMachine(lastConnection: Date(timeIntervalSince1970: 0))
            if existing == nil {
                guard let address = a["address"]?.string, !address.isEmpty else { throw AgentToolError(String(localized: "address is needed.")) }
                machine.remoteAddress = address
                machine.remotePort = "22"
            }
            if let address = a["address"]?.string, !address.isEmpty { machine.remoteAddress = address }
            if let port = a["port"]?.int { machine.remotePort = String(port) }
            if let value = a["name"]?.string { machine.name = value }
            if machine.name.isEmpty { machine.name = machine.remoteAddress }
            if let value = a["username"]?.string { machine.username = value }
            if machine.username.isEmpty { machine.username = RDMachine.defaultUsername }
            if let value = a["group"]?.string { machine.group = value }
            if a["tags"] != nil { machine.tags = a["tags"]?.strings ?? [] }
            if let value = a["comment"]?.string { machine.comment = value }
            if let value = a["proxy_command"]?.string { machine.proxyCommand = value }
            var identity: RDIdentity?
            if let reference = a["identity"]?.string, !reference.isEmpty {
                identity = try self.identity(named: reference)
            } else if let password = a["password"]?.string, !password.isEmpty {
                var own = existing.flatMap { store.associatedIdentity(for: $0) }.flatMap { $0.isPrivate ? $0 : nil }
                    ?? RDIdentity(authenticAutomatically: false)
                own.username = ""
                own.password = password
                own.privateKey = ""
                own.publicKey = ""
                own.isPrivate = true
                identity = own
            }
            let changes = [
                "\(machine.username)@\(machine.remoteAddress):\(machine.remotePort)",
                machine.group.isEmpty ? nil : "group \(machine.group)",
                machine.tags.isEmpty ? nil : "tags \(machine.tags.joined(separator: ", "))",
                a["identity"]?.string.map { "key \($0)" },
                a["password"] != nil ? "a password (hidden)" : nil,
                machine.proxyCommand.isEmpty ? nil : "proxy command \(machine.proxyCommand)",
            ].compactMap { $0 }.joined(separator: "\n")
            try await server.requireApproval(AgentRequest(
                client: client, tool: name,
                title: existing == nil ? String(localized: "Add server \(machine.name)") : String(localized: "Change server \(existing!.name)"),
                detail: changes, hosts: [machine.name], hostIDs: [machine.id.uuidString]
            ))
            if let identity {
                if identity.isPrivate { store.identityGroup.insert(identity) }
                if let previous = existing.flatMap({ store.associatedIdentity(for: $0) }), previous.isPrivate, previous.id != identity.id {
                    store.identityGroup.delete(previous.id)
                }
                machine.associatedIdentity = identity.id.uuidString
            }
            store.machineGroup.insert(machine)
            return .from(AgentHost(store.machineGroup[machine.id]))

        case "remove_host":
            let machine = try server.machine(named: a["host"]?.string ?? "")
            try await server.requireApproval(AgentRequest(client: client, tool: name, title: String(localized: "Remove server \(machine.name)"),
                                                          detail: "\(machine.remoteAddress):\(machine.remotePort)", hosts: [machine.name], hostIDs: [machine.id.uuidString]))
            if let identity = store.associatedIdentity(for: machine), identity.isPrivate {
                store.identityGroup.delete(identity.id)
            }
            for forward in store.portForwardGroup.forwards where forward.usingMachine == machine.id {
                server.environment?.stopForward(forward.id)
            }
            store.machineGroup.delete(machine.id)
            return ["removed": .string(machine.name)]

        case "list_identities":
            return .from(store.identityGroup.shared.map(AgentIdentity.init))

        case "add_identity":
            let label = a["name"]?.string ?? "Key"
            var identity = RDIdentity(lastRecentUsed: Date(timeIntervalSince1970: 0), authenticAutomatically: false)
            identity.name = label
            identity.group = a["group"]?.string ?? ""
            if a["generate"]?.bool == true {
                let pair = SSHKeyGenerator.ed25519(comment: label.replacingOccurrences(of: " ", with: "-"))
                identity.privateKey = pair.privateKey
                identity.publicKey = pair.publicKey
            } else {
                guard let key = a["private_key"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), key.contains("PRIVATE KEY") else {
                    throw AgentToolError(String(localized: "Give private_key (-----BEGIN … PRIVATE KEY-----) or generate: true."))
                }
                identity.privateKey = key + "\n"
                identity.publicKey = a["public_key"]?.string ?? ""
                identity.password = a["passphrase"]?.string ?? ""
            }
            let detail = a["generate"]?.bool == true
                ? String(localized: "A new Ed25519 key, made by Tamio")
                : (identity.keyAlgorithm != nil
                    ? String(localized: "A \(identity.keyAlgorithm!) key the agent provided")
                    : String(localized: "A private key the agent provided"))
            try await server.requireApproval(AgentRequest(
                client: client, tool: name, title: String(localized: "Add SSH key \(label)"),
                detail: detail,
                hosts: []
            ))
            store.identityGroup.insert(identity)
            return .from(AgentIdentity(identity))

        case "remove_identity":
            let identity = try self.identity(named: a["identity"]?.string ?? "")
            let users = AgentIdentity(identity).usedBy
            let detail = users.isEmpty ? String(localized: "Not used by any server") : String(localized: "Used by \(users.joined(separator: ", "))")
            try await server.requireApproval(AgentRequest(client: client, tool: name, title: String(localized: "Remove SSH key \(identity.displayName)"),
                                                          detail: detail, hosts: users))
            store.identityGroup.delete(identity.id)
            return ["removed": .string(identity.displayName)]

        case "list_snippets":
            let query = a["query"]?.string ?? ""
            return .from(store.snippetGroup.snippets.filter { query.isEmpty || $0.isQualifiedForSearch(text: query) }.map(AgentSnippet.init))

        case "add_snippet", "update_snippet":
            var snippet = name == "update_snippet" ? try self.snippet(named: a["snippet"]?.string ?? "") : RDSnippet()
            if let value = a["name"]?.string { snippet.name = value }
            if let value = a["code"]?.string { snippet.code = value }
            if let value = a["group"]?.string { snippet.group = value }
            if let value = a["comment"]?.string { snippet.comment = value }
            guard !snippet.name.isEmpty else { throw AgentToolError(String(localized: "name is needed.")) }
            let title = name == "add_snippet" ? String(localized: "Save snippet \(snippet.name)") : String(localized: "Change snippet \(snippet.name)")
            try await server.requireApproval(AgentRequest(client: client, tool: name,
                                                          title: title,
                                                          detail: snippet.code, hosts: []))
            store.snippetGroup.insert(snippet)
            return .from(AgentSnippet(snippet))

        case "remove_snippet":
            let snippet = try self.snippet(named: a["snippet"]?.string ?? "")
            try await server.requireApproval(AgentRequest(client: client, tool: name, title: String(localized: "Remove snippet \(snippet.name)"), detail: snippet.code, hosts: []))
            store.snippetGroup.delete(snippet.id)
            return ["removed": .string(snippet.name)]

        case "list_port_forwards":
            return .from(store.portForwardGroup.forwards.map { forward(for: $0, server: server) })

        case "add_port_forward":
            let machine = try server.machine(named: a["host"]?.string ?? "")
            guard let bind = a["bind_port"]?.int, let target = a["target_host"]?.string, let targetPort = a["target_port"]?.int else {
                throw AgentToolError(String(localized: "bind_port, target_host and target_port are needed."))
            }
            var forward = RDPortForward()
            forward.usingMachine = machine.id
            forward.forwardOrientation = a["direction"]?.string == "remote" ? .listenRemote : .listenLocal
            forward.bindPort = bind
            forward.targetHost = target
            forward.targetPort = targetPort
            let detail = forward.forwardOrientation == .listenLocal
                ? String(localized: "localhost:\(bind) → \(target):\(targetPort) (from the server)")
                : String(localized: "server port \(bind) → \(target):\(targetPort) (from this Mac)")
            try await server.requireApproval(AgentRequest(
                client: client, tool: name, title: String(localized: "Add port forward through \(machine.name)"),
                detail: detail,
                hosts: [machine.name]
            ))
            store.portForwardGroup.insert(forward)
            if a["start"]?.bool == true { server.environment?.startForward(forward.id) }
            return .from(Self.forward(for: forward, server: server))

        case "start_port_forward", "stop_port_forward", "remove_port_forward":
            let forward = try self.forward(named: a["forward"]?.string ?? "")
            let host = forward.usingMachine.map { store.machineGroup[$0].name } ?? "?"
            let title: String
            switch name {
            case "start_port_forward": title = String(localized: "Start port forward through \(host)")
            case "stop_port_forward": title = String(localized: "Stop port forward through \(host)")
            default: title = String(localized: "Remove port forward through \(host)")
            }
            try await server.requireApproval(AgentRequest(client: client, tool: name, title: title,
                                                          detail: "\(forward.bindPort) → \(forward.targetHost):\(forward.targetPort)", hosts: [host]))
            switch name {
            case "start_port_forward": server.environment?.startForward(forward.id)
            case "stop_port_forward": server.environment?.stopForward(forward.id)
            default:
                server.environment?.stopForward(forward.id)
                store.portForwardGroup.delete(forward.id)
                return ["removed": .string(forward.id.uuidString)]
            }
            return .from(Self.forward(for: forward, server: server))

        case "get_activity":
            var entries = server.log.entries
            if let reference = a["host"]?.string, !reference.isEmpty {
                let machine = try server.machine(named: reference)
                entries = server.log.entries(for: machine.id)
            }
            return .from(Array(entries.reversed().prefix(a["limit"]?.int ?? 50)))

        case "log_activity":
            let machines = try (a["hosts"]?.strings ?? []).map(server.machine(named:))
            guard !machines.isEmpty, let summary = a["summary"]?.string, !summary.isEmpty else {
                throw AgentToolError(String(localized: "hosts and summary are needed."))
            }
            let commands = a["commands"]?.strings ?? []
            let detail = [a["details"]?.string, commands.isEmpty ? nil : commands.map { "$ " + $0 }.joined(separator: "\n")]
                .compactMap { $0 }.joined(separator: "\n\n")
            let entry = AgentActivity(
                device: AgentActivityLog.deviceName, client: client, tool: "report",
                hosts: machines.map(\.id.uuidString), hostNames: machines.map(\.name),
                summary: summary, detail: detail, outcome: "reported", results: []
            )
            server.log.add(entry, task: a["task"]?.string)
            return ["recorded": .string(entry.id.uuidString)]

        default:
            throw AgentToolError(String(localized: "No tool named \(name)."))
        }
    }

    @MainActor
    static func identity(named reference: String) throws -> RDIdentity {
        let identities = TamioStore.shared.identityGroup.shared
        if let id = UUID(uuidString: reference), let identity = identities.first(where: { $0.id == id }) { return identity }
        let matches = identities.filter { $0.displayName.caseInsensitiveCompare(reference) == .orderedSame }
        if matches.count == 1 { return matches[0] }
        throw AgentToolError(matches.isEmpty ? String(localized: "No identity named \(reference). list_identities shows them.") : String(localized: "\(matches.count) identities are called \(reference); use its id."))
    }

    @MainActor
    static func snippet(named reference: String) throws -> RDSnippet {
        let snippets = TamioStore.shared.snippetGroup.snippets
        if let id = UUID(uuidString: reference), let snippet = snippets.first(where: { $0.id == id }) { return snippet }
        let matches = snippets.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
        if matches.count == 1 { return matches[0] }
        throw AgentToolError(matches.isEmpty ? String(localized: "No snippet named \(reference).") : String(localized: "\(matches.count) snippets are called \(reference); use its id."))
    }

    @MainActor
    static func forward(named reference: String) throws -> RDPortForward {
        guard let id = UUID(uuidString: reference),
              let forward = TamioStore.shared.portForwardGroup.forwards.first(where: { $0.id == id })
        else { throw AgentToolError(String(localized: "No port forward \(reference). list_port_forwards shows them.")) }
        return forward
    }

    @MainActor
    static func forward(for forward: RDPortForward, server: AgentServer) -> AgentForward {
        AgentForward(
            id: forward.id.uuidString,
            host: forward.usingMachine.map { TamioStore.shared.machineGroup[$0].name },
            direction: forward.forwardOrientation == .listenLocal ? "local" : "remote",
            bindPort: forward.bindPort,
            targetHost: forward.targetHost,
            targetPort: forward.targetPort,
            running: server.environment?.isForwarding(forward.id) ?? false
        )
    }
}
