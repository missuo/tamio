//
//  ServerActions.swift
//  Tamio (macOS)
//
//  The server context menu (Servers table, Home tiles) and the actions behind it.
//

import MachineStatusView
import TamioDesign
import TamioModule
import SwiftUI

enum ServerActions {
    @MainActor
    static func edit(_ machine: RDMachine.ID) {
        AppRouter.shared.serverEditor = .edit(machine)
    }

    static func duplicate(_ machine: RDMachine.ID) {
        let store = TamioStore.shared
        let original = store.machineGroup[machine]
        guard original.isNotPlaceholder() else { return }
        Dialogs.requiresConfirmation(
            message: String(localized: "Duplicate \(original.name)?"),
            confirmTitle: String(localized: "Duplicate")
        ) { confirmed in
            guard confirmed else { return }
            var copy = original
            copy.id = UUID()
            copy.name = original.name + " copy"
            // A private identity belongs to one server: the copy gets its own.
            if let raw = original.associatedIdentity, let id = UUID(uuidString: raw),
               store.identityGroup[id].isPrivate
            {
                var identity = store.identityGroup[id]
                identity.id = UUID()
                store.identityGroup.insert(identity)
                copy.associatedIdentity = identity.id.uuidString
            }
            store.machineGroup.insert(copy)
        }
    }

    @MainActor
    static func delete(_ machines: [RDMachine.ID]) {
        let store = TamioStore.shared
        guard !machines.isEmpty else { return }
        let message = machines.count == 1
            ? String(localized: "Delete \(store.machineGroup[machines[0]].name)?")
            : String(localized: "Delete \(machines.count) servers?")
        Dialogs.requiresConfirmation(
            message: message,
            informative: String(localized: "Port forwards through it stop working."),
            confirmTitle: String(localized: "Delete"),
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            for machine in machines {
                if let session = MonitorCenter.shared.session(for: machine) {
                    MonitorCenter.shared.end(session.id)
                }
                if let raw = store.machineGroup[machine].associatedIdentity, let id = UUID(uuidString: raw),
                   store.identityGroup[id].isPrivate
                {
                    store.identityGroup.delete(id)
                }
                store.machineGroup.delete(machine)
            }
            store.cleanRecentIfNeeded()
        }
    }

    /// For a server whose keys were replaced: its next host key is saved.
    static func forgetHostKey(_ machine: RDMachine.ID) {
        let read = TamioStore.shared.machineGroup[machine]
        guard read.isNotPlaceholder() else { return }
        Dialogs.requiresConfirmation(
            message: String(localized: "Forget the host key of \(read.name)?"),
            informative: String(localized: "The key the server presents on the next connection is saved as its key. Do this only when you know its keys were replaced."),
            confirmTitle: String(localized: "Forget")
        ) { confirmed in
            guard confirmed else { return }
            read.forgetHostKey()
        }
    }

    static func copyAddress(_ machine: RDMachine.ID) {
        let read = TamioStore.shared.machineGroup[machine]
        Dialogs.sendPasteboard(str: "\(read.remoteAddress):\(read.remotePort)")
    }

    static func copyCommand(_ machine: RDMachine.ID) {
        Dialogs.sendPasteboard(str: TamioStore.shared.machineGroup[machine].getCommand())
    }
}

/// The four ways into a server. Every surface that opens one (tiles, table rows,
/// context menus, the session switcher, the sidebar) uses these names, symbols and
/// descriptions, so a button means the same thing wherever it appears.
enum ServerTool: CaseIterable, Identifiable {
    case terminal
    case files
    case monitor

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: return String(localized: "Terminal")
        case .files: return String(localized: "Files")
        case .monitor: return String(localized: "Monitor")
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .monitor: return "gauge.with.dots.needle.33percent"
        }
    }

    /// Tooltip: what the tool does, in a sentence.
    var help: LocalizedStringKey {
        switch self {
        case .terminal: return "Open an SSH terminal on this server"
        case .files: return "Browse, upload and download files over SFTP"
        case .monitor: return "Watch CPU, memory, disk and network usage"
        }
    }

    /// Shows this tool for the server, reusing a session that is already open.
    @MainActor
    func show(_ machine: RDMachine.ID) {
        let router = AppRouter.shared
        switch self {
        case .terminal:
            if let existing = router.preferredTerminal(of: .server(machine)) {
                router.route = .terminal(existing.id)
            } else {
                router.openTerminal(machine: machine)
            }
        case .files: router.openFileTransfer(machine: machine)
        case .monitor: router.openMonitor(machine: machine)
        }
    }
}

/// Terminal, Files, Monitor, Show in Menu Bar, Edit, Duplicate, Copy Address,
/// Copy SSH Command, Forget Host Key, Delete.
struct ServerContextMenu: View {
    let machine: RDMachine.ID
    /// False where the tools already sit beside the menu (a tile's ⋯ button).
    var includesTools = true

    var body: some View {
        let router = AppRouter.shared
        Group {
            if includesTools {
                Button {
                    ServerTool.terminal.show(machine)
                } label: {
                    Label("Open Terminal", systemImage: ServerTool.terminal.systemImage)
                }
                Button {
                    ServerTool.files.show(machine)
                } label: {
                    Label("Open Files", systemImage: ServerTool.files.systemImage)
                }
                Button {
                    ServerTool.monitor.show(machine)
                } label: {
                    Label("Open Monitor", systemImage: ServerTool.monitor.systemImage)
                }
            }
            Button {
                router.openTerminal(machine: machine)
            } label: {
                Label("New Terminal", systemImage: "plus.rectangle")
            }
            Button {
                router.showInMenuBar(machine: machine)
            } label: {
                Label("Show in Menu Bar", systemImage: "menubar.rectangle")
            }
            Divider()
            Button {
                ServerActions.edit(machine)
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button {
                ServerActions.duplicate(machine)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                ServerActions.copyAddress(machine)
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            Button {
                ServerActions.copyCommand(machine)
            } label: {
                Label("Copy SSH Command", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Button {
                ServerActions.forgetHostKey(machine)
            } label: {
                Label("Forget Host Key…", systemImage: "key.slash")
            }
            Divider()
            Button(role: .destructive) {
                ServerActions.delete([machine])
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }
}

/// Live figures of a server while its monitor is open.
struct ServerLiveState {
    var cpu: Double?
    var memory: Double?
    var disk: Double?
    var receive: Double?
    var transmit: Double?

    /// From the server's open monitor, else its background status.
    @MainActor
    static func of(_ machine: RDMachine.ID) -> ServerLiveState {
        guard let session = LiveStatusCenter.shared.session(for: machine),
              session.phase == .connected, session.status.hasData
        else { return ServerLiveState() }
        let status = session.status
        let root = status.fileSystem.elements.first { $0.mountPoint == "/" }
            ?? status.fileSystem.elements.max { $0.percent < $1.percent }
        let physical = status.network.elements.filter { !NetworkFilter.isVirtual($0.device) }
        return ServerLiveState(
            cpu: Double(status.processor.summary.sumUsed),
            memory: status.memoryUsedPercent,
            disk: root.map { Double($0.percent) },
            receive: Double(physical.map(\.rxBytesPerSec).reduce(0, +)),
            transmit: Double(physical.map(\.txBytesPerSec).reduce(0, +))
        )
    }
}

/// Re-renders its content as the server's status changes.
struct ServerLiveReader<Content: View>: View {
    let machine: RDMachine.ID
    @ViewBuilder let content: (ServerLiveState) -> Content

    @ObservedObject private var live = LiveStatusCenter.shared
    @ObservedObject private var monitors = MonitorCenter.shared

    var body: some View {
        if let session = live.session(for: machine) {
            SessionReader(session: session) { content(ServerLiveState.of(machine)) }
        } else {
            content(ServerLiveState.of(machine))
        }
    }

    private struct SessionReader<Inner: View>: View {
        @ObservedObject var session: MonitorSession
        @ViewBuilder let inner: () -> Inner
        var body: some View { inner() }
    }
}

/// Terminal · Files · Monitor for one server, centred in a session page's toolbar,
/// so moving between the three views of a server is one click from any of them.
struct ServerToolSwitcher: View {
    let machine: RDMachine.ID
    let current: ServerTool

    var body: some View {
        Picker("View", selection: Binding(get: { current }, set: { $0.show(machine) })) {
            ForEach(ServerTool.allCases) { tool in
                Text(tool.title)
                    .help(tool.help)
                    .tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(String(localized: "Switch between this server's terminal, files and monitor"))
    }
}

/// The server and tool a session page shows, for the switcher in its toolbar.
struct ServerToolSwitch: Equatable {
    let machine: RDMachine.ID
    let current: ServerTool
}

private struct ServerToolSwitchKey: EnvironmentKey {
    static let defaultValue: ServerToolSwitch? = nil
}

extension EnvironmentValues {
    var serverToolSwitch: ServerToolSwitch? {
        get { self[ServerToolSwitchKey.self] }
        set { self[ServerToolSwitchKey.self] = newValue }
    }
}

extension View {
    /// Places the `ServerToolSwitcher` in the centre of the window toolbar. The
    /// page's toolbar (`pageToolbar`) lays it out with the rest, so this goes
    /// outside it.
    func serverToolSwitcher(machine: RDMachine.ID?, current: ServerTool) -> some View {
        environment(\.serverToolSwitch, machine.map { ServerToolSwitch(machine: $0, current: current) })
    }
}
