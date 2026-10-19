//
//  AgentSettings.swift
//  Tamio (macOS)
//
//  Settings › MCP: the server's switch (on by default), how to set an agent
//  up (commands, the skill, a prompt to paste), and what agents did lately.
//

import SwiftUI
import TamioDesign
import TamioModule

struct AgentServerSettings: View {
    @ObservedObject private var bridge = AgentBridge.shared

    var body: some View {
        RXDividedStack {
            SwitchRow(
                "MCP server",
                description: "Agents (Claude Code, Codex, any MCP client) can list your servers and their live status, and, when you approve, run commands and manage servers, keys, snippets and port forwards. They never get passwords or private keys.",
                isOn: $bridge.isEnabled
            )
            RXFormRow("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(bridge.isRunning ? Color.rxSuccess : Color.rxInkTertiary)
                        .frame(width: 7, height: 7)
                    Text(bridge.isRunning ? "Running" : "Off")
                        .font(.rxBody)
                        .foregroundStyle(.rxInkSecondary)
                }
            }
            RXFormRow("Approvals", description: "Every command and change asks you first. “Allow for 1 Hour” lets that agent go on without asking until then; “Always Allow” lets it work on its own, while you are away, until you revoke it here.") {
                EmptyView()
            }
            ForEach(bridge.alwaysAllowed, id: \.self) { client in
                RXFormRow(client, description: "Always allowed: runs commands and makes changes without asking.") {
                    Button("Revoke") { bridge.revokeAlways(client) }
                        .buttonStyle(.rx(size: .small))
                }
            }
        }
    }
}

struct AgentSetupSettings: View {
    @ObservedObject private var bridge = AgentBridge.shared
    @State private var installed: String?

    var body: some View {
        RXDividedStack {
            copyRow("Claude Code", description: "Run once in Terminal.", text: bridge.claudeCommand)
            copyRow("Codex", description: "Add to ~/.codex/config.toml.", text: bridge.codexConfig)
            RXFormRow("Tamio skill", description: installed ?? String(localized: "Teaches an agent the rules: read a server's activity first, run through Tamio, report what it does by other means.")) {
                HStack(spacing: RX.Space.s2) {
                    Button("Copy Command") { Dialogs.sendPasteboard(str: bridge.skillInstallCommand) }
                        .buttonStyle(.rx)
                        .help(bridge.skillInstallCommand)
                    Button("Install Skill") {
                        installed = bridge.installSkill().map { String(localized: "Not installed: \($0)") } ?? String(localized: "Installed in ~/.claude/skills/tamio.")
                    }
                    .buttonStyle(.rxPrimary)
                }
            }
            copyRow("Prompt", description: "Paste into any agent: where Tamio's MCP server and skill are, and how to use them.", text: bridge.agentPrompt)
        }
    }

    func copyRow(_ title: LocalizedStringKey, description: LocalizedStringKey, text: String) -> some View {
        RXFormRow(title, description: description, alignTop: true) {
            VStack(alignment: .trailing, spacing: RX.Space.s2) {
                Text(verbatim: text)
                    .font(.rxCode)
                    .foregroundStyle(.rxInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380, alignment: .leading)
                    .padding(RX.Space.s2)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.rxSurfaceSunken))
                Button("Copy") { Dialogs.sendPasteboard(str: text) }
                    .buttonStyle(.rx(size: .small))
            }
        }
    }
}

struct AgentActivitySettings: View {
    @ObservedObject private var log = AgentServer.shared.log
    /// The server shown, by id; nil for every server.
    @State private var server: String?

    /// Every server with activity, by id, under its current name or the last
    /// one recorded.
    private var servers: [(id: String, name: String)] {
        var names: [String: String] = [:]
        for entry in log.entries {
            for (id, name) in zip(entry.hosts, entry.hostNames) { names[id] = name }
        }
        for machine in TamioStore.shared.machineGroup.machines where names[machine.id.uuidString] != nil {
            names[machine.id.uuidString] = machine.name
        }
        return names.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var shown: [AgentActivity] {
        guard let server else { return log.entries }
        return log.entries.filter { $0.hosts.contains(server) }
    }

    var body: some View {
        RXDividedStack {
            if log.entries.isEmpty {
                RXFormRow("No activity yet", description: "What agents run and change, and what they report, shows here and on each server.") { EmptyView() }
            } else {
                RXFormRow("Server", description: "Show what agents did on one server, or on all of them.") {
                    Picker("Server", selection: $server) {
                        Text("All Servers").tag(String?.none)
                        ForEach(servers, id: \.id) { server in
                            Text(verbatim: server.name).tag(Optional(server.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if shown.isEmpty {
                    RXFormRow("No activity on this server", description: "Agents have not run or changed anything here yet.") { EmptyView() }
                }
                ForEach(shown.suffix(50).reversed()) { entry in
                    AgentActivityRow(entry: entry, showsHosts: server == nil)
                        .padding(.vertical, RX.Space.s2)
                }
                HStack {
                    Spacer()
                    Button("Clear Activity…") {
                        Dialogs.requiresConfirmation(
                            message: String(localized: "Clear all agent activity?"),
                            informative: String(localized: "It is cleared on this Mac only; with iCloud sync, other Macs keep theirs."),
                            confirmTitle: String(localized: "Clear"),
                            destructive: true
                        ) { if $0 { log.clear() } }
                    }
                    .buttonStyle(.rx(size: .small))
                }
                .padding(.vertical, RX.Space.s2)
            }
        }
    }
}

/// One entry: who, what, where, when, and how it went.
struct AgentActivityRow: View {
    let entry: AgentActivity
    var showsHosts = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: RX.Space.s2) {
                Image(systemName: (entry.steps?.count ?? 0) > 1 ? "list.bullet" : entry.tool == "report" ? "text.bubble" : entry.tool.hasPrefix("run_") ? "terminal" : "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(.rxAccent)
                    .frame(width: 14)
                Text(verbatim: entry.summary)
                    .font(.rxBodyStrong)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: RX.Space.s2)
                Text(verbatim: RXFormat.relative(entry.date))
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
                    .fixedSize()
            }
            Text(verbatim: [entry.client, entry.device, showsHosts ? entry.hostNames.joined(separator: ", ") : nil, entry.outcome]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.rxHelp)
                .foregroundStyle(entry.outcome.hasPrefix("declined") ? Color.rxWarning : Color.rxInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Whole or not at all: a short detail shows; a long one, or a
            // task's steps, waits for a click. Expanded, a task lists its
            // steps instead.
            let lines = entry.detail.split(separator: "\n").count
            if !entry.detail.isEmpty, !(expanded && (entry.steps?.count ?? 0) > 1) {
                if expanded || lines <= 3 {
                    Text(verbatim: entry.detail)
                        .font(.rxCode)
                        .foregroundStyle(.rxInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Label(
                        (entry.steps?.count ?? 0) > 1 ? String(localized: "Show \(entry.steps?.count ?? 0) steps") : String(localized: "Show \(lines) lines"),
                        systemImage: "chevron.right"
                    )
                    .font(.rxHelp)
                    .foregroundStyle(.rxAccent)
                }
            }
            if expanded, let steps = entry.steps, steps.count > 1 {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(index + 1). \(step.summary) · \(step.outcome)")
                            .font(.rxHelp)
                            .foregroundStyle(step.outcome.hasPrefix("declined") || step.results.contains { $0.exitCode != 0 }
                                ? Color.rxWarning : Color.rxInkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: AgentActivity.line(step))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.rxInk)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if expanded {
                ForEach(entry.results, id: \.host) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(result.host) · \(result.exitCode.map { String(localized: "exit \($0)") } ?? String(localized: "no exit code"))")
                            .font(.rxHelp)
                            .foregroundStyle(result.exitCode == 0 ? Color.rxInkSecondary : Color.rxDanger)
                        if !result.tail.isEmpty {
                            Text(result.tail.split(separator: "\n").suffix(6).joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.rxInkSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }
}
