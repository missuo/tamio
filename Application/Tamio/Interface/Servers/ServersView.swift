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
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .help(String(localized: "Import from SSH Config"))
            RedactionMenu()
            Button { router.openTerminals() } label: {
                Label("Open Terminals…", systemImage: "rectangle.stack.badge.plus")
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
                ServersTable(machines: sorted, selection: $selection)
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

/// None → Sensitive hides addresses → All hides names too.
struct RedactionMenu: View {
    @EnvironmentObject var store: TamioStore

    var body: some View {
        Menu {
            item("Show Everything", systemImage: "eye", level: .none)
            item("Hide Addresses", systemImage: "eye.slash", level: .sensitive)
            item("Hide Names and Addresses", systemImage: "eye.slash.fill", level: .all)
        } label: {
            Label("Privacy", systemImage: store.machineRedacted == .none ? "eye" : "eye.slash")
        }
        .help(store.machineRedacted.tooltip)
    }

    private func item(_ title: LocalizedStringKey, systemImage: String, level: RDMachine.RedactedLevel) -> some View {
        Button {
            store.machineRedacted = level
        } label: {
            if store.machineRedacted == level {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// States that details are hidden and offers the way back.
struct RedactionBanner: View {
    @EnvironmentObject var store: TamioStore

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.rxInkSecondary)
            Text(store.machineRedacted == .all ? String(localized: "Names and addresses hidden") : String(localized: "Addresses hidden"))
                .font(.rxBody)
                .foregroundStyle(.rxInkSecondary)
            Button("Show") { store.machineRedacted = .none }
                .buttonStyle(.rx(size: .small))
        }
        .padding(.horizontal, 12)
        .frame(height: RX.controlHeight)
        .background(Capsule().fill(Color.rxPill))
    }
}

// MARK: - Table

private struct ServersTable: View {
    let machines: [RDMachine]
    @Binding var selection: RDMachine.ID?
    @State private var width: CGFloat = 900

    var body: some View {
        let columns = ServerColumns(width: width)
        VStack(spacing: 0) {
            header(columns)
            Hairline()
            ForEach(Array(machines.enumerated()), id: \.element.id) { index, machine in
                ServerRow(machine: machine.id, columns: columns, selection: $selection)
                    .rxRise(index)
                    .transition(.opacity)
            }
        }
        // Rows make room for a new server and close up after a deleted one.
        .animation(.rxMove, value: machines.map(\.id))
        .readWidth($width)
        .rxCard(padding: RX.Space.s2)
    }

    func header(_ columns: ServerColumns) -> some View {
        HStack(spacing: 0) {
            TableHeaderLabel("Name").frame(maxWidth: .infinity, alignment: .leading)
            TableHeaderLabel("Address").frame(width: columns.address)
            if columns.showIdentity { TableHeaderLabel("Identity").frame(width: columns.identity) }
            if columns.showCPU { TableHeaderLabel("CPU").frame(width: columns.meter) }
            if columns.showMemory { TableHeaderLabel("Mem").frame(width: columns.meter) }
            if columns.showDisk { TableHeaderLabel("Disk").frame(width: columns.meter) }
            if columns.showNetwork { TableHeaderLabel("Net ↑ ↓").frame(width: columns.network) }
            if columns.showLastUsed { TableHeaderLabel("Last used").frame(width: columns.lastUsed) }
            Color.clear.frame(width: columns.actions, height: 1)
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableHeaderHeight)
    }
}

/// Which columns fit, in the order they give way: status first, then the
/// identity and last use.
struct ServerColumns {
    let address: CGFloat = 150
    let identity: CGFloat = 130
    let meter: CGFloat = 70
    let network: CGFloat = 150
    let lastUsed: CGFloat = 110
    let actions: CGFloat = 220
    let showCPU: Bool
    let showMemory: Bool
    let showDisk: Bool
    let showNetwork: Bool
    let showIdentity: Bool
    let showLastUsed: Bool

    init(width: CGFloat) {
        var room = width - (180 + 150 + 220 + 24)
        func fits(_ column: CGFloat) -> Bool {
            guard room >= column else { return false }
            room -= column
            return true
        }
        showCPU = fits(meter)
        showMemory = fits(meter)
        showDisk = fits(meter)
        showNetwork = fits(network)
        showIdentity = fits(identity)
        showLastUsed = fits(lastUsed)
    }
}

private struct ServerRow: View {
    let machine: RDMachine.ID
    let columns: ServerColumns
    @Binding var selection: RDMachine.ID?

    @EnvironmentObject var store: TamioStore
    @State private var hovered = false

    var body: some View {
        let read = store.machineGroup[machine]
        ServerLiveReader(machine: machine) { state in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    // The group follows the name, so every name starts at the
                    // same edge.
                    HStack(spacing: 6) {
                        if let flag = read.countryFlag { Text(flag).font(.system(size: 13)) }
                        RedactableText(read.name, redacted: store.machineRedacted == .all)
                            .font(.rxBody)
                            .foregroundStyle(.rxInk)
                            .lineLimit(1)
                        if !read.group.isEmpty {
                            RXTag(read.group)
                                .fixedSize()
                        }
                    }
                    if !read.comment.isEmpty, store.machineRedacted == .none {
                        Text(read.comment)
                            .font(.rxHelp)
                            .foregroundStyle(.rxInkSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RedactableText(read.remoteAddress, redacted: store.machineRedacted != .none)
                    .font(.rxCode)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: columns.address, alignment: .leading)
                if columns.showIdentity {
                    Text(identityName(read))
                        .font(.rxBody)
                        .foregroundStyle(read.associatedIdentity == nil ? Color.rxInkSecondary : Color.rxInk)
                        .lineLimit(1)
                        .frame(width: columns.identity, alignment: .leading)
                }
                // CPU, memory and disk read alike: a percentage, coloured
                // as it gets high.
                if columns.showCPU { percentText(state.cpu).frame(width: columns.meter, alignment: .leading) }
                if columns.showMemory { percentText(state.memory).frame(width: columns.meter, alignment: .leading) }
                if columns.showDisk { percentText(state.disk).frame(width: columns.meter, alignment: .leading) }
                if columns.showNetwork {
                    Group {
                        if let up = state.transmit, let down = state.receive {
                            Text("\(RXFormat.rateString(up))  \(RXFormat.rateString(down))")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.rxInk)
                                .lineLimit(1)
                        } else {
                            Text("—").foregroundStyle(.rxInkSecondary)
                        }
                    }
                    .frame(width: columns.network, alignment: .leading)
                }
                if columns.showLastUsed {
                    Text(RXFormat.relative(read.lastConnection))
                        .font(.rxBody)
                        .foregroundStyle(.rxInkSecondary)
                        .lineLimit(1)
                        .frame(width: columns.lastUsed, alignment: .leading)
                }
                HStack(spacing: RX.Space.s1) {
                    // All three bordered alike, so each reads as a button.
                    ForEach([ServerTool.files, .monitor, .terminal]) { tool in
                        Button(tool.title) { tool.show(machine) }
                            .buttonStyle(.rx(size: .small))
                            .help(tool.help)
                    }
                }
                .frame(width: columns.actions, alignment: .trailing)
            }
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableRowHeight)
        .rxRowBackground(selected: selection == machine, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { AppRouter.shared.openTerminal(machine: machine) })
        .simultaneousGesture(TapGesture(count: 1).onEnded { selection = machine })
        .contextMenu { ServerContextMenu(machine: machine) }
    }

    func percentText(_ value: Double?) -> some View {
        Group {
            if let value {
                Text("\(RXFormat.percent(value))%")
                    .font(.rxBody.monospacedDigit())
                    .foregroundStyle(rxUsageColor(value, base: .rxInk))
            } else {
                Text("—").foregroundStyle(.rxInkSecondary)
            }
        }
    }

    func identityName(_ machine: RDMachine) -> String {
        let user = machine.loginUsername(with: nil)
        guard let aid = machine.associatedIdentity, let uid = UUID(uuidString: aid) else {
            return user.isEmpty ? String(localized: "Automatic") : "\(user) · \(String(localized: "Automatic"))"
        }
        let identity = store.identityGroup[uid]
        guard identity.hasCredentials else { return String(localized: "Missing") }
        let credential = identity.isPrivate ? identity.authDescription : identity.displayName
        let login = machine.loginUsername(with: identity)
        return login.isEmpty ? credential : "\(login) · \(credential)"
    }
}
