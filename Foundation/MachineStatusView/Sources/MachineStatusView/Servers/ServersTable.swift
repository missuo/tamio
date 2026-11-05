//
//  ServersTable.swift
//  MachineStatusView
//
//  All servers in one list, each group a badge after the name: the columns
//  that fit the width (address, identity, CPU, memory, disk, traffic, last
//  use, the three tools), and on a narrow page two lines per server with the
//  tools in its menu. The redaction menu and banner go with it.
//

import SwiftUI
import TamioModule

public struct ServersTable<Context: View>: View {
    let machines: [RDMachine]
    @Binding var selection: RDMachine.ID?
    let context: (RDMachine.ID) -> Context
    @State private var width: CGFloat = 900

    public init(machines: [RDMachine], selection: Binding<RDMachine.ID?>, @ViewBuilder context: @escaping (RDMachine.ID) -> Context) {
        self.machines = machines
        _selection = selection
        self.context = context
    }

    public var body: some View {
        let columns = ServerColumns(width: width)
        VStack(spacing: 0) {
            if !columns.compact {
                header(columns)
                Hairline()
            }
            ForEach(Array(machines.enumerated()), id: \.element.id) { index, machine in
                ServerRow(machine: machine.id, columns: columns, selection: $selection, context: context)
                    .rxRise(index)
                    .transition(.opacity)
                if columns.compact, index < machines.count - 1 {
                    Hairline().padding(.horizontal, RX.Space.s3)
                }
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
/// identity and last use. Under `compactWidth` there is no row of columns at
/// all: each server takes two lines.
public struct ServerColumns {
    public let address: CGFloat = 150
    public let identity: CGFloat = 130
    public let meter: CGFloat = 70
    public let network: CGFloat = 150
    public let lastUsed: CGFloat = 110
    public let actions: CGFloat = 220
    public let compact: Bool
    public let showCPU: Bool
    public let showMemory: Bool
    public let showDisk: Bool
    public let showNetwork: Bool
    public let showIdentity: Bool
    public let showLastUsed: Bool

    public static var compactWidth: CGFloat { 600 }

    public init(width: CGFloat) {
        compact = width < Self.compactWidth
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

private struct ServerRow<Context: View>: View {
    let machine: RDMachine.ID
    let columns: ServerColumns
    @Binding var selection: RDMachine.ID?
    let context: (RDMachine.ID) -> Context

    @EnvironmentObject var store: TamioStore
    @Environment(\.serverActions) private var actions
    @State private var hovered = false

    var body: some View {
        let read = store.machineGroup[machine]
        ServerLiveReader(machine: machine) { state in
            if columns.compact {
                compactRow(read, state)
            } else {
                wideRow(read, state)
            }
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: columns.compact ? nil : RX.tableRowHeight)
        .rxRowBackground(selected: selection == machine, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { actions.openTerminal(machine) })
        .simultaneousGesture(TapGesture(count: 1).onEnded { selection = machine })
        .contextMenu { context(machine) }
    }

    /// The name, its group and comment, then every column that fits.
    func wideRow(_ read: RDMachine, _ state: ServerLiveState) -> some View {
        HStack(spacing: 0) {
            nameColumn(read)
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
                    .foregroundStyle(read.associatedIdentity == nil && !read.signsInWithoutCredentials ? Color.rxInkSecondary : Color.rxInk)
                    .lineLimit(1)
                    .frame(width: columns.identity, alignment: .leading)
            }
            // CPU, memory and disk read alike: a percentage, coloured
            // as it gets high.
            if columns.showCPU { percentText(state.cpu).frame(width: columns.meter, alignment: .leading) }
            if columns.showMemory { percentText(state.memory).frame(width: columns.meter, alignment: .leading) }
            if columns.showDisk { percentText(state.disk).frame(width: columns.meter, alignment: .leading) }
            if columns.showNetwork {
                networkText(state)
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
                    Button(tool.title) { tool.show(machine, with: actions) }
                        .buttonStyle(.rx(size: .small))
                        .help(tool.help)
                }
            }
            .frame(width: columns.actions, alignment: .trailing)
        }
    }

    /// Three lines, nothing cut short: the name with its group, the address
    /// with the identity, then the readings; the tools are in the menu.
    func compactRow(_ read: RDMachine, _ state: ServerLiveState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: RX.Space.s2) {
                nameColumn(read)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    context(machine)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
                .fixedSize()
            }
            HStack(spacing: RX.Space.s2) {
                RedactableText(read.remoteAddress, redacted: store.machineRedacted != .none)
                    .font(.rxCode)
                    .foregroundStyle(.rxInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("·").foregroundStyle(.rxInkTertiary)
                Text(identityName(read))
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: RX.Space.s3) {
                meter("CPU", state.cpu)
                meter("Mem", state.memory)
                meter("Disk", state.disk)
                Spacer(minLength: RX.Space.s2)
                networkText(state)
            }
        }
        .padding(.vertical, RX.Space.s2)
    }

    func nameColumn(_ read: RDMachine) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // The group follows the name, so every name starts at the
            // same edge.
            HStack(spacing: 6) {
                if let flag = read.countryFlag { Text(flag).font(.system(size: 13)).fixedSize() }
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
    }

    func meter(_ title: LocalizedStringKey, _ value: Double?) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.rxInkTertiary)
            percentText(value)
        }
    }

    func networkText(_ state: ServerLiveState) -> some View {
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
        if machine.signsInWithoutCredentials {
            return "\(user) · \(String(localized: "No password or key"))"
        }
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

// MARK: - Redaction

/// None → Sensitive hides addresses → All hides names too.
public struct RedactionMenu: View {
    @EnvironmentObject var store: TamioStore

    public init() {}

    public var body: some View {
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
public struct RedactionBanner: View {
    @EnvironmentObject var store: TamioStore

    public init() {}

    public var body: some View {
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
