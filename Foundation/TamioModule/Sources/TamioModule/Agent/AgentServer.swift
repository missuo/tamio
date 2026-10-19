//
//  AgentServer.swift
//  TamioModule
//
//  Tamio's MCP server: agents list and manage servers, identities, snippets
//  and port forwards, and run commands, through Tamio. Secrets only go in:
//  an agent may set a password or a key, or have Tamio generate one, but no
//  response carries a password, a private key or a passphrase. Anything that
//  changes something or runs a command is approved by the user first.
//

import Foundation

/// What the app supplies: the user's approval, live metrics and port forward
/// sessions, which live above this module.
@MainActor
public protocol AgentEnvironment: AnyObject {
    /// Asks the user; true to go ahead.
    func approve(_ request: AgentRequest) async -> Bool
    /// Live readings for a server, nil when it has none.
    func metrics(for machine: RDMachine.ID) -> JSONValue?
    func isForwarding(_ forward: RDPortForward.ID) -> Bool
    func startForward(_ forward: RDPortForward.ID)
    func stopForward(_ forward: RDPortForward.ID)
}

/// One action an agent wants to take, as the approval shows it.
public struct AgentRequest: Sendable {
    public let client: String
    public let tool: String
    /// "Run on 3 servers", "Add server prod-web-01".
    public let title: String
    /// The command, or what changes.
    public let detail: String
    public let hosts: [String]
    /// The servers' ids, for their activity.
    public var hostIDs: [String] = []
    /// The task the action serves, as the agent named it ("Install nginx").
    public var task: String?
}

@MainActor
public final class AgentServer {
    public static let shared = AgentServer()
    public static let protocolVersion = "2025-06-18"

    public weak var environment: AgentEnvironment?
    public let log = AgentActivityLog()

    /// Clients the user allowed to act without asking, until when.
    private var allowedUntil: [String: Date] = [:]
    /// The action the tool being called asked approval for; recorded when
    /// the call ends.
    private var pendingActivity: AgentRequest?
    /// The task the tool being called serves, as the agent named it.
    private var pendingTask: String?

    public init() {}

    /// Lets a client act without asking for an hour.
    public func allowForAnHour(_ client: String) {
        allowedUntil[client] = Date().addingTimeInterval(3600)
    }

    static let alwaysAllowedKey = "sb.moe.tamio.mcp.alwaysAllowed"

    /// Clients the user lets act without asking until they revoke it, kept
    /// across launches: for agents left to work alone.
    public var alwaysAllowed: [String] {
        (UserDefaults.standard.stringArray(forKey: Self.alwaysAllowedKey) ?? []).sorted()
    }

    public func allowAlways(_ client: String) {
        guard !alwaysAllowed.contains(client) else { return }
        UserDefaults.standard.set(alwaysAllowed + [client], forKey: Self.alwaysAllowedKey)
    }

    public func revokeAlways(_ client: String) {
        UserDefaults.standard.set(alwaysAllowed.filter { $0 != client }, forKey: Self.alwaysAllowedKey)
        allowedUntil[client] = nil
    }

    // MARK: - JSON-RPC

    /// Handles one JSON-RPC message; nil for a notification (no reply).
    public func handle(_ line: String, client session: AgentSession) async -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return Self.error(id: .null, code: -32700, message: "Parse error")
        }
        let id = message["id"] ?? .null
        guard let method = message["method"]?.string else {
            return id == .null ? nil : Self.error(id: id, code: -32600, message: "Invalid request")
        }
        let params = message["params"] ?? [:]
        let isNotification = message["id"] == nil

        let result: Result<JSONValue, RPCError>
        switch method {
        case "initialize":
            if let name = params["clientInfo"]?["name"]?.string { session.clientName = name }
            let requested = params["protocolVersion"]?.string ?? Self.protocolVersion
            result = .success([
                "protocolVersion": .string(requested),
                "capabilities": ["tools": ["listChanged": false], "resources": ["listChanged": false]],
                "serverInfo": ["name": "tamio", "version": .string(Self.appVersion)],
                "instructions": """
                Tamio holds the user's SSH servers. Use list_hosts to see them, get_metrics for live load, \
                run_command to run a shell command on one or more servers (the user approves it, and Tamio \
                signs in with its own saved credentials), and the add_/update_/remove_ tools to manage servers, \
                identities (SSH keys), snippets and port forwards. Passwords and private keys can be set but \
                are never returned. Prefer generate: true in add_identity and give the user the public key.
                Before working on a server, call get_activity for it to see what earlier agents did, on any \
                of the user's Macs. Give every call that changes something a task: a short name for the \
                goal it serves ("Install nginx"), the same for every step toward that goal, so the steps \
                are kept as one entry in the server's history. Whenever you change a server by any other \
                means (your own ssh, scp, a deploy tool), call log_activity for it with what you did and \
                the commands you ran, and the same task, so the next agent knows.
                """,
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            result = .success([:])
        case "tools/list":
            result = .success(["tools": .array(AgentTools.definitions)])
        case "tools/call":
            let name = params["name"]?.string ?? ""
            let arguments = params["arguments"] ?? [:]
            result = .success(await callTool(name, arguments: arguments, client: session.clientName))
        case "resources/list":
            result = .success(["resources": [
                ["uri": "tamio://hosts", "name": "Servers", "description": "Every server Tamio can reach, without secrets", "mimeType": "application/json"],
            ]])
        case "resources/read":
            let uri = params["uri"]?.string ?? ""
            if uri == "tamio://hosts" {
                result = .success(["contents": [[
                    "uri": "tamio://hosts", "mimeType": "application/json",
                    "text": .string(JSONValue.from(hosts(matching: [:])).encodedString(pretty: true)),
                ]]])
            } else {
                result = .failure(RPCError(code: -32002, message: "Unknown resource \(uri)"))
            }
        default:
            result = .failure(RPCError(code: -32601, message: "Method not found: \(method)"))
        }
        if isNotification { return nil }
        switch result {
        case let .success(value):
            return (["jsonrpc": "2.0", "id": id, "result": value] as JSONValue).encodedString()
        case let .failure(error):
            return Self.error(id: id, code: error.code, message: error.message)
        }
    }

    struct RPCError: Error {
        let code: Int
        let message: String
    }

    static func error(id: JSONValue, code: Int, message: String) -> String {
        (["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]] as JSONValue).encodedString()
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Tools

    /// A tool's reply: its JSON as text, or an error the agent reads.
    func callTool(_ name: String, arguments: JSONValue, client: String) async -> JSONValue {
        pendingActivity = nil
        pendingTask = arguments["task"]?.string
        do {
            let output = try await AgentTools.call(name, arguments: arguments, server: self, client: client)
            recordPending(outcome: "ok", output: output)
            return ["content": [["type": "text", "text": .string(output.encodedString(pretty: true))]], "isError": false]
        } catch {
            let message = (error as? AgentToolError)?.message ?? error.localizedDescription
            recordPending(outcome: message, output: nil)
            return ["content": [["type": "text", "text": .string(message)]], "isError": true]
        }
    }

    /// Every action that asked for approval goes in the activity of the
    /// servers it concerns, whatever its outcome.
    private func recordPending(outcome: String, output: JSONValue?) {
        guard let request = pendingActivity else { return }
        pendingActivity = nil
        var results: [AgentActivity.Result] = []
        var summaryOutcome = outcome
        if let runs = output?.array, request.tool.hasPrefix("run_") {
            results = runs.map {
                AgentActivity.Result(host: $0["host"]?.string ?? "", exitCode: $0["exitCode"]?.int, tail: String(($0["output"]?.string ?? "").suffix(2000)))
            }
            let codes = Dictionary(grouping: results, by: { $0.exitCode.map { "exit \($0)" } ?? "failed" })
            summaryOutcome = codes.map { "\($0.key) on \($0.value.count)" }.sorted().joined(separator: ", ")
        }
        log.add(AgentActivity(
            device: AgentActivityLog.deviceName, client: request.client, tool: request.tool,
            hosts: request.hostIDs, hostNames: request.hosts,
            summary: request.title, detail: request.detail, outcome: summaryOutcome, results: results
        ), task: pendingTask)
    }

    /// Asks the user unless the client may act for now; throws when refused.
    func requireApproval(_ request: AgentRequest) async throws {
        var request = request
        if request.hostIDs.isEmpty {
            request.hostIDs = request.hosts.compactMap { name in
                TamioStore.shared.machineGroup.machines.first { $0.name == name }?.id.uuidString
            }
        }
        request.task = pendingTask
        pendingActivity = request
        if alwaysAllowed.contains(request.client) { return }
        if let until = allowedUntil[request.client], until > Date() { return }
        guard let environment else { throw AgentToolError(String(localized: "Tamio is not ready to ask the user.")) }
        guard await environment.approve(request) else {
            throw AgentToolError(String(localized: "declined by the user: \(request.title)"))
        }
    }

    // MARK: - Hosts

    /// Every server, or those a filter names: query, group, tag.
    func hosts(matching arguments: JSONValue) -> [AgentHost] {
        var machines = TamioStore.shared.machineGroup.machines
        if let query = arguments["query"]?.string, !query.isEmpty {
            machines = machines.filter { $0.isQualifiedForSearch(text: query) }
        }
        if let group = arguments["group"]?.string, !group.isEmpty {
            machines = machines.filter { $0.group.caseInsensitiveCompare(group) == .orderedSame }
        }
        if let tag = arguments["tag"]?.string, !tag.isEmpty {
            machines = machines.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        }
        return machines.map(AgentHost.init)
    }

    /// A server by id, name or address.
    func machine(named reference: String) throws -> RDMachine {
        let machines = TamioStore.shared.machineGroup.machines
        if let id = UUID(uuidString: reference), let machine = machines.first(where: { $0.id == id }) { return machine }
        let matches = machines.filter {
            $0.name.caseInsensitiveCompare(reference) == .orderedSame || $0.remoteAddress == reference
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw AgentToolError(String(localized: "\(matches.count) servers match \(reference); use its id.")) }
        throw AgentToolError(String(localized: "No server named \(reference). list_hosts shows them."))
    }

    /// The servers a run targets: hosts (ids or names), a group, a tag, or all.
    func targets(_ arguments: JSONValue) throws -> [RDMachine] {
        let spec = arguments["targets"] ?? arguments
        var result: [RDMachine] = []
        if spec["all"]?.bool == true {
            result = TamioStore.shared.machineGroup.machines
        }
        for reference in (spec["hosts"]?.strings ?? []) + (spec["host"]?.strings ?? []) {
            result.append(try machine(named: reference))
        }
        if let group = spec["group"]?.string, !group.isEmpty {
            result += TamioStore.shared.machineGroup.machines.filter { $0.group.caseInsensitiveCompare(group) == .orderedSame }
        }
        if let tag = spec["tag"]?.string, !tag.isEmpty {
            result += TamioStore.shared.machineGroup.machines.filter { $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
        }
        var seen = Set<RDMachine.ID>()
        result = result.filter { seen.insert($0.id).inserted }
        guard !result.isEmpty else { throw AgentToolError(String(localized: "Name the servers: targets {hosts: [...]} or {group}, {tag} or {all: true}.")) }
        return result
    }
}

public struct AgentToolError: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// One client connection: what it said it is.
public final class AgentSession: @unchecked Sendable {
    public var clientName = String(localized: "Agent")
    public init() {}
}
