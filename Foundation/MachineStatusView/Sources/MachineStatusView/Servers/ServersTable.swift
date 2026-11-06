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
    /// Two lines per server under `ServerColumns.compactWidth`. Which columns
    /// a wide row shows is decided by `ServerColumnsLayout` as it places them.
    @State private var compact = false
    /// Held, not observed: the pointer moving between rows redraws only the
    /// highlight, never the table or its rows.
    @State private var hover = RowHoverModel()
    @State private var arrived = false
    /// The rows' width with the window's sidebar open: the columns are
    /// chosen for it, so hiding the sidebar widens the names instead of
    /// adding a column.
    @Environment(\.rxOpenWidth) private var openWidth

    public init(machines: [RDMachine], selection: Binding<RDMachine.ID?>, @ViewBuilder context: @escaping (RDMachine.ID) -> Context) {
        self.machines = machines
        _selection = selection
        self.context = context
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !compact {
                header
                Hairline()
            }
            rows
        }
        // Rows make room for a new server and close up after a deleted one.
        .animation(.rxMove, value: machines.map(\.id))
        // Kept as whether it is narrow, not as the width: the table is drawn
        // again only when it changes, not at every point the sidebar slides
        // or the window is resized.
        .onGeometryChange(for: Bool.self) { min($0.size.width, openWidth - RX.Space.s2 * 2) < ServerColumns.compactWidth } action: { new in
            if new != compact { compact = new }
        }
        .rxCard(padding: RX.Space.s2)
        .transformEnvironment(\.rxOpenWidth) { $0 -= RX.Space.s2 * 2 }
        .task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            arrived = true
        }
    }

    @ViewBuilder var rows: some View {
        if compact {
            VStack(spacing: 0) {
                ForEach(Array(machines.enumerated()), id: \.element.id) { index, machine in
                    row(machine.id, index: index, hovered: false, tracksHover: true)
                    if index < machines.count - 1 {
                        Hairline().padding(.horizontal, RX.Space.s3)
                    }
                }
            }
        } else {
            // One hover region for the whole list, the row worked out from the
            // fixed row height, and one highlight that moves to it: with a
            // region per row and per button, and a row redrawn as the pointer
            // crossed it, scrolling hit tested hundreds of regions and
            // measured every row again at each frame.
            // Lazy: only the rows in view are laid out and drawn, at each step
            // of a sidebar slide or a resize, however many servers there are.
            LazyVStack(spacing: 0) {
                ForEach(Array(machines.enumerated()), id: \.element.id) { index, machine in
                    row(machine.id, index: index, hovered: false, tracksHover: false)
                }
            }
            .background(alignment: .top) { RowHoverHighlight(model: hover) }
            .onContinuousHover { [hover, count = machines.count] phase in
                var under: Int?
                if case let .active(location) = phase, location.y >= 0 {
                    let index = Int((location.y / RX.tableRowHeight).rounded(.down))
                    if index < count { under = index }
                }
                if under != hover.index { hover.index = under }
            }
            .environment(\.rxButtonsTrackHover, false)
        }
    }

    func row(_ machine: RDMachine.ID, index: Int, hovered: Bool, tracksHover: Bool) -> some View {
        ServerRow(
            machine: machine,
            compact: compact,
            selected: selection == machine,
            hovered: hovered,
            tracksHover: tracksHover,
            select: { selection = machine },
            context: context
        )
        // Drawn again only when what it shows changes: the menu closure is
        // new at every update of the table, so SwiftUI could never tell.
        .equatable()
        // Rows rise as the page arrives, not as they scroll into view.
        .rxRise(index, enabled: !arrived)
        .transition(.opacity)
    }

    var header: some View {
        ServerColumnsLayout(openWidth: openWidth - RX.Space.s2 * 2) {
            TableHeaderLabel("Name").frame(maxWidth: .infinity, alignment: .leading)
            TableHeaderLabel("Address").frame(maxWidth: .infinity, alignment: .leading)
            TableHeaderLabel("Identity").frame(maxWidth: .infinity, alignment: .leading)
            TableHeaderLabel("CPU").frame(maxWidth: .infinity, alignment: .leading)
            TableHeaderLabel("Mem").frame(maxWidth: .infinity, alignment: .leading)
            TableHeaderLabel("Disk").frame(maxWidth: .infinity, alignment: .leading)
            TableHeaderLabel("Net ↑ ↓").frame(maxWidth: .infinity, alignment: .leading)
            TableHeaderLabel("Last used").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(height: 1)
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableHeaderHeight)
    }
}

/// A wide row's nine columns, or the header's: name, address, identity, CPU,
/// memory, disk, traffic, last use and the tools, in that order. The columns
/// that fit are worked out from the width the row is placed at, in the same
/// pass, so the header and every row agree at every width a sidebar slide or
/// a resize passes through, with no frame drawn from an older width. The rest
/// are placed out of sight.
struct ServerColumnsLayout: Layout {
    /// The table's width with the window's sidebar open; the columns are
    /// chosen for the narrower of it and the width the row has.
    var openWidth: CGFloat = .infinity

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 900, height: RX.tableRowHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        // The decisions are the table's, which counts the row's own margins.
        let columns = ServerColumns(width: min(bounds.width + RX.Space.s3 * 2, openWidth))
        let fixed: [(width: CGFloat, shown: Bool)?] = [
            nil,
            (columns.address, true),
            (columns.identity, columns.showIdentity),
            (columns.meter, columns.showCPU),
            (columns.meter, columns.showMemory),
            (columns.meter, columns.showDisk),
            (columns.network, columns.showNetwork),
            (columns.lastUsed, columns.showLastUsed),
            (columns.actions, true),
        ]
        let taken = fixed.compactMap { $0 }.filter(\.shown).map(\.width).reduce(0, +)
        let name = max(0, bounds.width - taken)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() where index < fixed.count {
            let column = fixed[index]
            let width = column?.width ?? name
            if column?.shown ?? true {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: width, height: bounds.height))
                x += width
            } else {
                // At its own width, so it is not measured again at each step.
                subview.place(at: CGPoint(x: bounds.maxX + 100_000, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: width, height: bounds.height))
            }
        }
    }
}

/// Which columns fit, in the order they give way: status first, then the
/// identity and last use. Under `compactWidth` there is no row of columns at
/// all: each server takes two lines.
public struct ServerColumns: Equatable {
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

private struct ServerRow<Context: View>: View, Equatable {
    let machine: RDMachine.ID
    let compact: Bool
    let selected: Bool
    /// From the table, which tracks the pointer for every row at once.
    let hovered: Bool
    /// In the compact list, where rows differ in height, each tracks its own.
    let tracksHover: Bool
    let select: () -> Void
    let context: (RDMachine.ID) -> Context

    @EnvironmentObject var store: TamioStore
    @Environment(\.serverActions) private var actions
    /// The table's width with the sidebar open (the table takes its own
    /// margins off).
    @Environment(\.rxOpenWidth) private var openWidth
    @State private var ownHover = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.machine == rhs.machine && lhs.compact == rhs.compact && lhs.selected == rhs.selected
            && lhs.hovered == rhs.hovered && lhs.tracksHover == rhs.tracksHover
    }

    var body: some View {
        let read = store.machineGroup[machine]
        ServerLiveReader(machine: machine) { state in
            if compact {
                compactRow(read, state)
            } else {
                wideRow(read, state)
            }
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: compact ? nil : RX.tableRowHeight)
        .rxRowBackground(selected: selected, hovered: hovered || ownHover)
        .contentShape(Rectangle())
        .modifier(RowHover(enabled: tracksHover, hovered: $ownHover))
        .gesture(TapGesture(count: 2).onEnded { actions.openTerminal(machine) })
        .simultaneousGesture(TapGesture(count: 1).onEnded(select))
        .contextMenu { context(machine) }
    }

    /// The name, its group and comment, then every column that fits.
    func wideRow(_ read: RDMachine, _ state: ServerLiveState) -> some View {
        ServerColumnsLayout(openWidth: openWidth) {
            nameColumn(read)
                .frame(maxWidth: .infinity, alignment: .leading)
            RedactableText(read.remoteAddress, redacted: store.machineRedacted != .none)
                .font(.rxCode)
                .foregroundStyle(.rxInk)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(identityName(read))
                .font(.rxBody)
                .foregroundStyle(read.associatedIdentity == nil && !read.signsInWithoutCredentials ? Color.rxInkSecondary : Color.rxInk)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            // CPU, memory and disk read alike: a percentage, coloured
            // as it gets high.
            percentText(state.cpu).frame(maxWidth: .infinity, alignment: .leading)
            percentText(state.memory).frame(maxWidth: .infinity, alignment: .leading)
            percentText(state.disk).frame(maxWidth: .infinity, alignment: .leading)
            networkText(state)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(RXFormat.relative(read.lastConnection))
                .font(.rxBody)
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: RX.Space.s1) {
                // All three bordered alike, so each reads as a button.
                ForEach([ServerTool.files, .monitor, .terminal]) { tool in
                    Button(tool.title) { tool.show(machine, with: actions) }
                        .buttonStyle(.rx(size: .small))
                        .help(tool.help)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
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
                    Label("More", rx: "ellipsis")
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

@MainActor
private final class RowHoverModel: ObservableObject {
    @Published var index: Int?
}

/// The `row-hover` fill under the row the pointer is over.
private struct RowHoverHighlight: View {
    @ObservedObject var model: RowHoverModel

    var body: some View {
        if let index = model.index {
            RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                .fill(Color.rxRowHover)
                .frame(height: RX.tableRowHeight)
                .offset(y: CGFloat(index) * RX.tableRowHeight)
                .allowsHitTesting(false)
        }
    }
}

private struct RowHover: ViewModifier {
    let enabled: Bool
    @Binding var hovered: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onHover { hovered = $0 }
        } else {
            content
        }
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
            Label("Privacy", rx: store.machineRedacted == .none ? "eye" : "eye.slash")
        }
        .help(store.machineRedacted.tooltip)
    }

    private func item(_ title: LocalizedStringKey, systemImage: String, level: RDMachine.RedactedLevel) -> some View {
        Button {
            store.machineRedacted = level
        } label: {
            if store.machineRedacted == level {
                Label(title, rx: "checkmark")
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
            Image(rx: "eye.slash")
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
