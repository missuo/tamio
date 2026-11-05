//
//  StatusCard.swift
//  MachineStatusView
//
//  A server's live status card on Home: small, three readings that matter
//  most (CPU, memory, disk) side by side, no rotation. A click opens the
//  inspector with everything else. The ⋯ menu and the context menu are the
//  app's: they name what it can do with a server.
//

import MachineStatus
import SwiftUI
import TamioModule

/// The card's measurements, for the grid and the page around it.
public enum StatusCardMetrics {
    /// Small: three or four across a usual window.
    public static let minimumWidth: CGFloat = 240
}

public struct StatusCard<More: View, Context: View>: View {
    let machine: RDMachine.ID
    var selected = false
    var select: () -> Void = {}
    let more: () -> More
    let context: () -> Context

    @EnvironmentObject var store: TamioStore
    @Environment(\.serverActions) private var actions
    @ObservedObject private var live = LiveStatusCenter.shared
    @ObservedObject private var monitors = MonitorCenter.shared
    @State private var hovered = false

    public init(
        machine: RDMachine.ID,
        selected: Bool = false,
        select: @escaping () -> Void = {},
        @ViewBuilder more: @escaping () -> More,
        @ViewBuilder context: @escaping () -> Context
    ) {
        self.machine = machine
        self.selected = selected
        self.select = select
        self.more = more
        self.context = context
    }

    public var body: some View {
        let read = store.machineGroup[machine]
        VStack(alignment: .leading, spacing: RX.Space.s3) {
            header(read)
            if let session = live.session(for: machine) {
                StatusSlots(session: session, machine: machine)
            } else {
                unfollowed(read)
            }
        }
        .padding(.horizontal, RX.Space.s3)
        .padding(.top, RX.Space.s3)
        .padding(.bottom, RX.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rxCard(padding: 0)
        .overlay(
            RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                .strokeBorder(Color.rxAccent.opacity(selected ? 0.7 : hovered ? 0.3 : 0), lineWidth: selected ? 1.5 : 1)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .animation(.easeOut(duration: 0.15), value: selected)
        )
        .contentShape(RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous))
        .onHover { hovered = $0 }
        // The click selects at once; a double click also opens a terminal.
        // (A count-2 gesture in front of a count-1 one holds every click
        // back until the double-click time has passed.)
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded { actions.openTerminal(machine) })
        .contextMenu { context() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(read.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }

    func header(_ read: RDMachine) -> some View {
        HStack(spacing: RX.Space.s2) {
            StatusPhaseDot(session: live.session(for: machine))
            if let flag = read.countryFlag {
                Text(flag)
                    .font(.system(size: 15))
                    // Fixed: without it, the title's layoutPriority(1) squeezes
                    // the emoji down to a sliver on long names.
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            RedactableText(read.name.uppercased(), redacted: store.machineRedacted == .all)
                .font(.system(size: 13, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(.rxInk)
                .lineLimit(1)
                .layoutPriority(1)
            if let session = live.session(for: machine) {
                SystemLine(session: session)
            }
            Spacer(minLength: RX.Space.s2)
            HStack(spacing: 2) {
                cardButton("Terminal", systemImage: "terminal") { actions.openTerminal(machine) }
                Menu {
                    more()
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
                .fixedSize()
                .help(String(localized: "More actions"))
            }
            // Fixed: the width the card is proposed stops here, so the
            // buttons are not laid out again at every step of a sidebar
            // slide or a window resize.
            .fixedSize()
        }
    }

    func cardButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
        .foregroundStyle(.rxAccent)
        .help(title)
    }

    func unfollowed(_ read: RDMachine) -> some View {
        HStack(spacing: RX.Space.s3) {
            Image(systemName: "key")
                .foregroundStyle(.rxInkSecondary)
            Text(live.isEnabled ? "Add a password or key to see live status." : "Live status is off in Settings.")
                .font(.rxBody)
                .foregroundStyle(.rxInkSecondary)
            Spacer()
            if live.isEnabled {
                Button("Edit Server") { actions.edit(machine) }
                    .buttonStyle(.rx(size: .small))
            }
        }
        .frame(height: StatusSlots.height)
    }
}

/// Live / connecting / offline, as a dot before the name.
struct StatusPhaseDot: View {
    let session: MonitorSession?

    var body: some View {
        if let session {
            Observed(session: session)
        } else {
            Circle().fill(Color.rxInkTertiary).frame(width: 7, height: 7)
        }
    }

    private struct Observed: View {
        @ObservedObject var session: MonitorSession

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .help(help)
        }

        var color: Color {
            switch session.phase {
            case .connected: return session.status.hasData ? .rxSuccess : .rxWarning
            case .connecting: return .rxWarning
            case .failed, .closed: return .rxDanger
            }
        }

        var help: String {
            switch session.phase {
            case .connected: return String(localized: "Live")
            case .connecting: return String(localized: "Connecting…")
            case let .failed(message): return String(localized: "Offline: \(message)")
            case .closed: return String(localized: "Closed")
            }
        }
    }
}

/// The OS logo, then as much of "macOS 26.6.2 · up 25d 5h" as fits whole:
/// all of it, the OS name alone, or the logo alone. Nothing is cut short;
/// what does not fit is in the inspector.
struct SystemLine: View {
    @ObservedObject var session: MonitorSession
    var showsText = true

    var body: some View {
        let system = session.status.system
        let release = system.releaseName
        let uptime = system.uptimeSec > 0 ? String(localized: "up \(RXFormat.duration(system.uptimeSec))") : ""
        FirstThatFits {
            if showsText, !release.isEmpty, !uptime.isEmpty { line(release + " · " + uptime) }
            if showsText, !release.isEmpty { line(release) }
            OSLogo(session: session, size: 12)
        }
    }

    func line(_ text: String) -> some View {
        HStack(spacing: 4) {
            OSLogo(session: session, size: 12)
            Text(text)
                .font(.rxHelp)
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Slots

public struct StatusSlots: View {
    @ObservedObject var session: MonitorSession
    let machine: RDMachine.ID

    public static var height: CGFloat { 60 }

    public init(session: MonitorSession, machine: RDMachine.ID) {
        self.session = session
        self.machine = machine
    }

    public var body: some View {
        Group {
            switch session.phase {
            case let .failed(message) where !session.status.hasData:
                HStack(spacing: RX.Space.s2) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.rxDanger)
                    // The card's height is fixed: the whole message when
                    // it fits, else the word, with the message on hover.
                    ViewThatFits(in: .vertical) {
                        Text("Offline · \(message)")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Offline")
                    }
                    .font(.rxBody)
                    .foregroundStyle(.rxInkSecondary)
                    .help(message)
                    Spacer()
                }
            default:
                if session.status.hasData {
                    slots
                } else {
                    HStack(spacing: RX.Space.s2) {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                            .font(.rxBody)
                            .foregroundStyle(.rxInkSecondary)
                        Spacer()
                    }
                }
            }
        }
        .frame(height: Self.height)
    }

    /// CPU, memory and the root disk, each a ring with its percentage.
    var slots: some View {
        let status = session.status
        let root = status.fileSystem.elements.first { $0.mountPoint == "/" }
            ?? status.fileSystem.elements.max { $0.percent < $1.percent }
        return HStack(spacing: 0) {
            reading("CPU", help: status.cores == 1 ? String(localized: "1 core") : String(localized: "\(status.cores) cores")) {
                RingGauge(fraction: Double(status.processor.summary.sumUsed) / 100)
            }
            reading("MEM", help: String(localized: "\(ShortBytes.string(status.memoryUsedKB * 1000)) of \(ShortBytes.string(status.memory.memTotal * 1000))")) {
                RingGauge(
                    fraction: status.memoryUsedPercent / 100,
                    cache: status.memory.memTotal > 0 ? status.memoryCacheKB / status.memory.memTotal : 0
                )
            }
            reading("DISK", help: root.map { String(localized: "\($0.used) of \($0.size)") } ?? "") {
                RingGauge(fraction: Double(root?.percent ?? 0) / 100, empty: root == nil)
            }
        }
    }

    func reading(_ caption: LocalizedStringKey, help: String, @ViewBuilder gauge: () -> some View) -> some View {
        VStack(spacing: 4) {
            gauge()
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
        }
        // Fixed, so the width the column proposes never reaches the gauge
        // or its caption: at every step of the sidebar's slide they would
        // be laid out again, and the text resolved again.
        .fixedSize()
        .frame(minWidth: 0, maxWidth: .infinity)
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The cards of Home

/// Home's body: an empty state before the first server, the cards that match
/// the group filter and search, or a note that none do. The app wraps it in
/// its page (toolbar, inspector) and supplies the cards' menus.
public struct ServerCardsGrid<More: View, Context: View>: View {
    let search: String
    @Binding var selection: RDMachine.ID?
    let more: (RDMachine.ID) -> More
    let context: (RDMachine.ID) -> Context

    @EnvironmentObject var store: TamioStore
    @Environment(\.serverActions) private var actions
    @ObservedObject private var filterStore = HomeGroupFilterStore.shared

    public init(
        search: String,
        selection: Binding<RDMachine.ID?>,
        @ViewBuilder more: @escaping (RDMachine.ID) -> More,
        @ViewBuilder context: @escaping (RDMachine.ID) -> Context
    ) {
        self.search = search
        _selection = selection
        self.more = more
        self.context = context
    }

    var filter: HomeGroupFilter {
        filterStore.selection.resolved(in: store.machineGroup.machines)
    }

    public var body: some View {
        let machines = filter.machines(in: store, search: search)
        if store.machineGroup.machines.isEmpty {
            EmptyStateView(
                "Save a server to reach it in one click",
                systemImage: "server.rack",
                message: "Its live load, CPU, memory, disk and traffic show here, and it opens a terminal or files in one click.",
                actionTitle: "New Server"
            ) {
                actions.newServer()
            }
            .frame(maxWidth: .infinity)
            .rxCard()
        } else if machines.isEmpty {
            EmptyStateView(filter.noMatchTitle(for: search), systemImage: "magnifyingglass")
                .rxCard()
        } else {
            CardGrid(minimumWidth: StatusCardMetrics.minimumWidth, spacing: RX.Space.s3) {
                ForEach(machines) { machine in
                    // A click shows the card's server in the panel; the panel's
                    // close button and Esc put it away.
                    StatusCard(machine: machine.id, selected: selection == machine.id, select: {
                        if selection != machine.id { selection = machine.id }
                    }, more: { more(machine.id) }, context: { context(machine.id) })
                }
            }
        }
    }
}
