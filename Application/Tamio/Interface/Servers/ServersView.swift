//
//  ServersView.swift
//  Tamio (macOS)
//
//  All servers in one list, each group a badge after the name, with search,
//  redaction, Open Terminals and New Server.
//

import MachineStatusView
import TamioDesign
import TamioModule
import SwiftUI

struct ServersView: View {
    @EnvironmentObject var store: TamioStore
    @ObservedObject var router = AppRouter.shared

    @State private var searchText = ""
    @State private var selection: RDMachine.ID?
    @State private var importsSSHConfig = false

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
        PageScaffold(
            search: $searchText,
            searchPrompt: "Search servers",
            primary: ToolbarAction("New Server", systemImage: "plus", primary: true) {
                router.presentNewServer = true
            }
        ) {
        } trailing: {
            Button { importsSSHConfig = true } label: {
                Label("Import…", rx: "square.and.arrow.down")
            }
            .help(String(localized: "Import from SSH Config"))
            RedactionMenu()
            Button { router.openTerminals() } label: {
                Label("Open Terminals…", rx: "rectangle.stack.badge.plus")
            }
            .help(String(localized: "Pick several servers and open a terminal on each"))
            .disabled(store.machineGroup.machines.isEmpty)
        } header: {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                PageTitle("Servers")
                if store.machineRedacted != .none {
                    RedactionBanner()
                }
            }
        } content: {
            if store.machineGroup.machines.isEmpty {
                EmptyStateView(
                    "No servers yet",
                    systemImage: "server.rack",
                    actionTitle: "New Server"
                ) {
                    router.presentNewServer = true
                }
                .rxCard()
            } else if filtered.isEmpty {
                EmptyStateView("No matches", systemImage: "magnifyingglass")
                .rxCard()
            } else {
                ServersTable(machines: sorted, selection: $selection) { machine in
                    ServerContextMenu(machine: machine)
                }
            }
        }
        .sheet(isPresented: $importsSSHConfig) {
            SSHConfigImportSheet().environmentObject(store)
        }
        .background {
            // ⌘⌫ deletes the selected row.
            Button("Delete") {
                if let selection { ServerActions.delete([selection]) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selection == nil)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}
