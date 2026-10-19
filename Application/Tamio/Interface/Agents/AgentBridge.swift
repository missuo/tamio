//
//  AgentBridge.swift
//  Tamio (macOS)
//
//  What the MCP server needs from the app: the user's approval (a sheet on
//  the window naming the agent, the action, the command and the servers),
//  live status from the server cards' sessions, and port forward sessions.
//  Starts the server when Settings › MCP has it on, which is the default.
//

import MachineStatus
import MachineStatusView
import SwiftUI
import TamioModule

@MainActor
final class AgentBridge: ObservableObject, AgentEnvironment {
    static let shared = AgentBridge()
    static let enabledKey = "sb.moe.tamio.mcp.enabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            apply()
        }
    }

    @Published private(set) var isRunning = false
    /// Agents allowed to act without asking until revoked.
    @Published private(set) var alwaysAllowed = AgentServer.shared.alwaysAllowed

    func revokeAlways(_ client: String) {
        AgentServer.shared.revokeAlways(client)
        alwaysAllowed = AgentServer.shared.alwaysAllowed
    }

    /// Where agents launch the server from.
    static var helperPath: String {
        Bundle.main.url(forResource: "tamio-mcp", withExtension: nil)?.path
            ?? "/Applications/Tamio.app/Contents/Resources/tamio-mcp"
    }

    static var skillFolder: URL? {
        Bundle.main.url(forResource: "skills", withExtension: nil)?.appendingPathComponent("tamio")
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        AgentServer.shared.environment = self
        apply()
    }

    private func apply() {
        if isEnabled { AgentSocket.shared.start() } else { AgentSocket.shared.stop() }
        isRunning = AgentSocket.shared.isRunning
    }

    // MARK: - AgentEnvironment

    func approve(_ request: AgentRequest) async -> Bool {
        Mac.activate()
        let serversPrefix = String(localized: "Servers: ")
        let moreServers = request.hosts.count > 12 ? " " + String(localized: "and \(request.hosts.count - 12) more") : ""
        let hosts = request.hosts.isEmpty ? "" : "\n\n" + serversPrefix + request.hosts.prefix(12).joined(separator: ", ") + moreServers
        let detail = request.detail.count > 1200 ? String(request.detail.prefix(1200)) + "…" : request.detail
        let forTask = request.task.map { String(localized: "For: \($0)\n\n") } ?? ""
        return await withCheckedContinuation { continuation in
            Mac.alert(
                message: String(localized: "\(request.client) wants to: \(request.title)"),
                informative: forTask + detail + hosts,
                buttons: [
                    String(localized: "Allow"),
                    String(localized: "Allow for 1 Hour"),
                    String(localized: "Always Allow"),
                    String(localized: "Deny")
                ]
            ) { index, _ in
                switch index {
                case 0: continuation.resume(returning: true)
                case 1:
                    AgentServer.shared.allowForAnHour(request.client)
                    continuation.resume(returning: true)
                case 2:
                    AgentServer.shared.allowAlways(request.client)
                    self.alwaysAllowed = AgentServer.shared.alwaysAllowed
                    continuation.resume(returning: true)
                default: continuation.resume(returning: false)
                }
            }
        }
    }

    func prepareMetrics(for machines: [RDMachine.ID]) {
        LiveStatusCenter.shared.lease(machines)
    }

    func metrics(for machine: RDMachine.ID) async -> JSONValue? {
        guard let session = await LiveStatusCenter.shared.requestSession(for: machine), session.status.hasData else { return nil }
        let status = session.status
        let root = status.fileSystem.elements.first { $0.mountPoint == "/" }
        let physical = status.network.elements.filter { !NetworkFilter.isVirtual($0.device) }
        func number(_ value: Double) -> JSONValue { .number((value * 10).rounded() / 10) }
        return [
            "os": .string(status.system.releaseName),
            "hostname": .string(status.system.hostname),
            "uptimeSeconds": number(status.system.uptimeSec),
            "cores": .number(Double(status.cores)),
            "cpuPercent": number(Double(status.processor.summary.sumUsed)),
            "load": [number(Double(status.system.load1)), number(Double(status.system.load5)), number(Double(status.system.load15))],
            "memoryPercent": number(status.memoryUsedPercent),
            "memoryUsedBytes": number(status.memoryUsedKB * 1000),
            "memoryTotalBytes": number(status.memory.memTotal * 1000),
            "swapUsedBytes": number(max(0, status.memory.swapTotal - status.memory.swapFree) * 1000),
            "disks": .array(status.fileSystem.elements.map {
                ["mount": .string($0.mountPoint), "usedPercent": number(Double($0.percent)), "used": .string($0.used), "size": .string($0.size)]
            }),
            "rootDiskPercent": root.map { number(Double($0.percent)) } ?? .null,
            "networkUpBytesPerSecond": number(Double(physical.map(\.txBytesPerSec).reduce(0, +))),
            "networkDownBytesPerSecond": number(Double(physical.map(\.rxBytesPerSec).reduce(0, +))),
            "trafficSinceBootUpBytes": number(Double(physical.map(\.txBytesTotal).reduce(0, +))),
            "trafficSinceBootDownBytes": number(Double(physical.map(\.rxBytesTotal).reduce(0, +))),
            "updated": .string(session.lastUpdate.map { ISO8601DateFormatter().string(from: $0) } ?? ""),
        ]
    }

    func isForwarding(_ forward: RDPortForward.ID) -> Bool {
        PortForwardBackend.shared.sessionExists(withPortForwardID: forward)
    }

    func startForward(_ forward: RDPortForward.ID) {
        PortForwardBackend.shared.createSession(withPortForwardID: forward)
    }

    func stopForward(_ forward: RDPortForward.ID) {
        PortForwardBackend.shared.endSession(withPortForwardID: forward)
    }

    // MARK: - Setup

    var claudeCommand: String { "claude mcp add tamio -- \"\(Self.helperPath)\"" }

    var codexConfig: String {
        """
        [mcp_servers.tamio]
        command = "\(Self.helperPath)"
        """
    }

    var skillInstallCommand: String {
        let source = Self.skillFolder?.path ?? "/Applications/Tamio.app/Contents/Resources/skills/tamio"
        return "mkdir -p ~/.claude/skills && cp -R \"\(source)\" ~/.claude/skills/"
    }

    /// For any agent: how to reach Tamio and where its instructions are.
    var agentPrompt: String {
        """
        My SSH servers are in Tamio, which runs an MCP server. Connect to it as a stdio MCP server \
        with the command "\(Self.helperPath)" (Claude Code: \(claudeCommand)). \
        Read the Tamio skill at "\(Self.skillFolder?.appendingPathComponent("SKILL.md").path ?? "Tamio.app/Contents/Resources/skills/tamio/SKILL.md")" \
        (also at https://github.com/missuo/tamio/tree/main/skills/tamio) and follow it: call get_activity before \
        working on a server, run commands with run_command, give each change a task naming its goal ("Install \
        nginx") so its steps are kept together, and call log_activity for anything you change by other means. Tamio never gives out passwords or private keys; ask me to approve changes.
        """
    }

    /// Copies the skill into Claude Code's skills folder; the error, if any.
    func installSkill() -> String? {
        guard let source = Self.skillFolder else { return "The skill is missing from this copy of Tamio." }
        let skills = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/skills", isDirectory: true)
        let target = skills.appendingPathComponent("tamio", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
