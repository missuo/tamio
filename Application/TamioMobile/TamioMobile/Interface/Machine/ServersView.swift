//
//  ServersView.swift
//  TamioMobile
//
//  All servers in one list, as on the Mac: each group a badge after the
//  name, with search, redaction, Open Terminals and New Server. The server
//  menu and the actions behind it are here too.
//

import MachineStatusView
import SwiftUI
import TamioModule

struct ServersView: View {
    @EnvironmentObject var store: TamioStore
    @Environment(\.serverActions) private var actions
    @State private var searchText = ""
    @State private var selection: RDMachine.ID?

    var filtered: [RDMachine] {
        let machines = store.machineGroup.machines
        guard !searchText.isEmpty else { return machines }
        return machines.filter { $0.isQualifiedForSearch(text: searchText) }
    }

    /// By name; a server's group is a badge after it, not a section.
    var sorted: [RDMachine] {
        filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                if store.machineRedacted != .none {
                    RedactionBanner()
                }
                if store.machineGroup.machines.isEmpty {
                    EmptyStateView(
                        "No servers yet",
                        systemImage: "server.rack",
                        actionTitle: "New Server"
                    ) {
                        actions.newServer()
                    }
                    .rxCard()
                } else if filtered.isEmpty {
                    EmptyStateView("No matches", systemImage: "magnifyingglass")
                        .rxCard()
                } else {
                    ServersTable(machines: sorted, selection: $selection) { machine in
                        ServerMenuItems(machine: machine)
                    }
                }
            }
            .padding(.horizontal, RX.Space.s4)
            .padding(.top, RX.Space.s1)
            .padding(.bottom, RX.Space.s6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle("Servers")
        .searchable(text: $searchText, prompt: "Search servers")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                RedactionMenu()
                Button { ServerActions.openTerminals() } label: {
                    Label("Open Terminals…", systemImage: "rectangle.stack.badge.plus")
                }
                .help(String(localized: "Pick several servers and open a terminal on each"))
                .disabled(store.machineGroup.machines.isEmpty)
                Button { actions.newServer() } label: {
                    Label("New Server", systemImage: "plus")
                }
            }
        }
    }
}

/// Terminal, Files, Monitor, New Terminal; Edit, Duplicate, Copy Address,
/// Copy SSH Command, Forget Host Key; Delete: the Mac's server menu.
struct ServerMenuItems: View {
    let machine: RDMachine.ID
    /// False where the tools already sit beside the menu (a card's ⋯ button).
    var includesTools = true
    @Environment(\.serverActions) private var actions

    var body: some View {
        Group {
            if includesTools {
                Button { actions.openTerminal(machine) } label: {
                    Label("Open Terminal", systemImage: ServerTool.terminal.systemImage)
                }
                Button { actions.openFiles(machine) } label: {
                    Label("Open Files", systemImage: ServerTool.files.systemImage)
                }
                Button { actions.openMonitor(machine) } label: {
                    Label("Open Monitor", systemImage: ServerTool.monitor.systemImage)
                }
            }
            Button { TerminalManager.shared.begin(for: machine, force: true) } label: {
                Label("New Terminal", systemImage: "plus.rectangle")
            }
            Divider()
            Button { actions.edit(machine) } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button { ServerActions.duplicate(machine) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button { ServerActions.copyAddress(machine) } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            Button { ServerActions.copyCommand(machine) } label: {
                Label("Copy SSH Command", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Button { ServerActions.forgetHostKey(machine) } label: {
                Label("Forget Host Key…", systemImage: "key.slash")
            }
            Divider()
            Button(role: .destructive) { ServerActions.delete([machine]) } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }
}

@MainActor
enum ServerActions {
    /// The editor over the page, for a new server or an existing one.
    static func edit(_ machine: RDMachine.ID?) {
        TamioUtil.presentModalSheet(rootView: NavigationStack {
            EditMachineView(requestMachine: machine)
        }
        .environmentObject(TamioStore.shared))
    }

    static func openMonitor(_ machine: RDMachine.ID) {
        do {
            let existing = MonitorCenter.shared.session(for: machine)
            let session = try MonitorCenter.shared.begin(for: machine)
            // An existing monitor is brought forward even when sessions do
            // not open automatically; a new one waits for the setting.
            guard existing != nil || TamioStore.shared.openInterfaceAutomatically else { return }
            let host = UIHostingController(rootView: DefaultModalPresenter {
                MonitorView(session: session)
            }.environmentObject(TamioStore.shared))
            host.modalTransitionStyle = .coverVertical
            host.modalPresentationStyle = .formSheet
            host.preferredContentSize = preferredPopOverSize
            PresentationQueue.present(next: host)
        } catch {
            UIBridge.presentError(with: "Cannot open monitor")
        }
    }

    static func duplicate(_ machine: RDMachine.ID) {
        let store = TamioStore.shared
        let original = store.machineGroup[machine]
        guard original.isNotPlaceholder() else { return }
        UIBridge.requiresConfirmation(
            message: String(localized: "Duplicate \(original.name)?"),
            confirmTitle: String(localized: "Duplicate"),
            destructive: false
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

    static func delete(_ machines: [RDMachine.ID]) {
        let store = TamioStore.shared
        guard !machines.isEmpty else { return }
        let message = machines.count == 1
            ? String(localized: "Delete \(store.machineGroup[machines[0]].name)?")
            : String(localized: "Delete \(machines.count) servers?")
        UIBridge.requiresConfirmation(
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
        UIBridge.requiresConfirmation(
            message: String(localized: "Forget the host key of \(read.name)?"),
            informative: String(localized: "The key the server presents on the next connection is saved as its key. Do this only when you know its keys were replaced."),
            confirmTitle: String(localized: "Forget"),
            destructive: false
        ) { confirmed in
            guard confirmed else { return }
            read.forgetHostKey()
        }
    }

    static func copyAddress(_ machine: RDMachine.ID) {
        let read = TamioStore.shared.machineGroup[machine]
        UIBridge.sendPasteboard(str: read.remoteAddress)
    }

    static func copyCommand(_ machine: RDMachine.ID) {
        UIBridge.sendPasteboard(str: TamioStore.shared.machineGroup[machine].getCommand())
    }

    /// Pick servers, then open a terminal for each.
    static func openTerminals() {
        Task {
            let machines = await TamioUtil.selectMachine()
            // Terminals present themselves through PresentationQueue once
            // connected, so the picker sheet still animating out is fine.
            await MainActor.run {
                for machine in machines {
                    TerminalManager.shared.begin(for: machine, force: true)
                }
            }
        }
    }
}

extension ServerActionHandlers {
    /// What the shared server views do on iOS: sessions that present
    /// themselves, sheets, alerts, the pasteboard.
    @MainActor static var ios: ServerActionHandlers {
        ServerActionHandlers(
            openTerminal: { TerminalManager.shared.begin(for: $0) },
            openTerminalRunning: { TerminalManager.shared.begin(for: $0, running: $1) },
            openFiles: { FileTransferManager.shared.begin(for: $0) },
            openMonitor: { ServerActions.openMonitor($0) },
            edit: { ServerActions.edit($0) },
            newServer: { ServerActions.edit(nil) },
            copy: { UIBridge.sendPasteboard(str: $0) },
            confirm: { message, informative, confirmTitle, destructive, completion in
                UIBridge.requiresConfirmation(message: message, informative: informative, confirmTitle: confirmTitle, destructive: destructive, confirmation: completion)
            }
        )
    }
}
