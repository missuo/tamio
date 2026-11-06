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
        Dialogs.sendPasteboard(str: read.remoteAddress)
    }

    static func copyCommand(_ machine: RDMachine.ID) {
        Dialogs.sendPasteboard(str: TamioStore.shared.machineGroup[machine].getCommand())
    }
}

extension ServerTool {
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

extension ServerActionHandlers {
    /// What the shared server views do on the Mac: routes, dialogs, the
    /// pasteboard.
    @MainActor static var mac: ServerActionHandlers {
        ServerActionHandlers(
            openTerminal: { ServerTool.terminal.show($0) },
            openTerminalRunning: { AppRouter.shared.openTerminal(machine: $0, initialCommand: $1) },
            openFiles: { ServerTool.files.show($0) },
            openMonitor: { ServerTool.monitor.show($0) },
            edit: { ServerActions.edit($0) },
            newServer: { AppRouter.shared.presentNewServer = true },
            copy: { Dialogs.sendPasteboard(str: $0) },
            confirm: { message, informative, confirmTitle, destructive, completion in
                Dialogs.requiresConfirmation(message: message, informative: informative, confirmTitle: confirmTitle, destructive: destructive, confirmation: completion)
            }
        )
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
                    Label("Open Terminal", rx: ServerTool.terminal.systemImage)
                }
                Button {
                    ServerTool.files.show(machine)
                } label: {
                    Label("Open Files", rx: ServerTool.files.systemImage)
                }
                Button {
                    ServerTool.monitor.show(machine)
                } label: {
                    Label("Open Monitor", rx: ServerTool.monitor.systemImage)
                }
            }
            Button {
                router.openTerminal(machine: machine)
            } label: {
                Label("New Terminal", rx: "plus.rectangle")
            }
            Button {
                router.showInMenuBar(machine: machine)
            } label: {
                Label("Show in Menu Bar", rx: "menubar.rectangle")
            }
            Divider()
            Button {
                ServerActions.edit(machine)
            } label: {
                Label("Edit…", rx: "pencil")
            }
            Button {
                ServerActions.duplicate(machine)
            } label: {
                Label("Duplicate", rx: "plus.square.on.square")
            }
            Button {
                ServerActions.copyAddress(machine)
            } label: {
                Label("Copy Address", rx: "doc.on.doc")
            }
            Button {
                ServerActions.copyCommand(machine)
            } label: {
                Label("Copy SSH Command", rx: "chevron.left.forwardslash.chevron.right")
            }
            Button {
                ServerActions.forgetHostKey(machine)
            } label: {
                Label("Forget Host Key…", rx: "key.slash")
            }
            Divider()
            Button(role: .destructive) {
                ServerActions.delete([machine])
            } label: {
                Label("Delete…", rx: "trash")
            }
        }
    }
}

/// Terminal · Files · Monitor for one server, centred in a session page's toolbar,
/// so moving between the three views of a server is one click from any of them.
struct ServerToolSwitcher: View {
    let machine: RDMachine.ID
    let current: ServerTool

    var body: some View {
        RXTabs(ServerTool.allCases.map { .init($0, Text($0.title), help: Text($0.help)) }, selection: current) { tool in
            tool.show(machine)
        }
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
