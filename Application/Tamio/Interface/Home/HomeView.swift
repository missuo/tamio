//
//  HomeView.swift
//  Tamio (macOS)
//
//  Start page: every server's live status card in a dense grid, straight
//  under the toolbar (a group switcher at the top left, search and New Server
//  at the top right, no title row), and beside them the inspector of the card
//  that is selected.
//

import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

/// Which servers Home shows: every one, one group's, or those in no group.
/// Kept across launches as a string.
enum HomeGroupFilter: Hashable, RawRepresentable {
    case all
    case group(String)
    case ungrouped

    init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "ungrouped": self = .ungrouped
        default:
            guard rawValue.hasPrefix("group:") else { return nil }
            self = .group(String(rawValue.dropFirst("group:".count)))
        }
    }

    var rawValue: String {
        switch self {
        case .all: return "all"
        case .ungrouped: return "ungrouped"
        case let .group(name): return "group:" + name
        }
    }

    func includes(_ machine: RDMachine) -> Bool {
        switch self {
        case .all: return true
        case .ungrouped: return machine.group.isEmpty
        case let .group(name): return machine.group == name
        }
    }

    /// The chosen filter, or All once no server is left in what it named.
    func resolved(in machines: [RDMachine]) -> HomeGroupFilter {
        switch self {
        case .all:
            return .all
        case .ungrouped:
            return machines.contains { $0.group.isEmpty } ? .ungrouped : .all
        case let .group(name):
            return machines.contains { $0.group == name } ? self : .all
        }
    }
}

/// Kept in memory and written through to UserDefaults so the segmented
/// control's binding updates synchronously during AppKit's click handler
/// (a computed Binding over @AppStorage reads the previous snapshot until the
/// next render pass, which makes NSSegmentedControl snap back for one frame).
@MainActor
private final class HomeGroupFilterStore: ObservableObject {
    static let shared = HomeGroupFilterStore()
    private static let key = "sb.moe.tamio.home.group"

    @Published var selection: HomeGroupFilter {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set(selection.rawValue, forKey: Self.key)
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        selection = HomeGroupFilter(rawValue: raw) ?? .all
    }
}

struct HomeView: View {
    @State private var search = ""

    var body: some View {
        // The toolbar is set here, on a view that redraws only when the
        // search changes: rebuilding toolbar items on every resize or group
        // switch makes AppKit re-layout the toolbar item mid-click.
        HomeContent(search: search)
            .pageChrome()
            .pageToolbar(
                primary: ToolbarAction("New Server", systemImage: "plus", primary: true) {
                    AppRouter.shared.presentNewServer = true
                },
                trailingMetrics: .group,
                search: ($search, "Search servers")
            ) {
                HomeGroupSwitcher()
            } trailing: {}
    }
}

/// All · each group · No Group at the leading end of Home's toolbar, drawn
/// like the Terminal · Files · Monitor switcher of a session page: one click
/// shows only that group's cards.
private struct HomeGroupSwitcher: View {
    @EnvironmentObject var store: TamioStore
    @ObservedObject private var filterStore = HomeGroupFilterStore.shared

    struct Segment: Hashable {
        let filter: HomeGroupFilter
        let rawTitle: String
        let count: Int

        var title: LocalizedStringKey {
            switch filter {
            case .all: return "All"
            case .ungrouped: return "No Group"
            case let .group(name): return LocalizedStringKey(name)
            }
        }
    }

    var segments: [Segment] {
        let machines = store.machineGroup.machines
        let groups = Set(machines.map(\.group)).filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        // Only once a server has a group: with none, there is nothing to
        // choose between.
        guard !groups.isEmpty else { return [] }
        var items = [Segment(filter: .all, rawTitle: "All", count: machines.count)]
        for name in groups {
            items.append(Segment(
                filter: .group(name),
                rawTitle: name,
                count: machines.filter { $0.group == name }.count
            ))
        }
        let ungrouped = machines.filter { $0.group.isEmpty }.count
        if ungrouped > 0 {
            items.append(Segment(filter: .ungrouped, rawTitle: "No Group", count: ungrouped))
        }
        return items
    }

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let segments = segments
        let active = filterStore.selection.resolved(in: store.machineGroup.machines)
        if !segments.isEmpty {
            HStack(spacing: 0) {
                ForEach(segments, id: \.filter) { segment in
                    let isSelected = segment.filter == active
                    Button {
                        guard filterStore.selection != segment.filter else { return }
                        filterStore.selection = segment.filter
                    } label: {
                        Text(segment.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.primary.opacity(isSelected ? 0.96 : 0.78))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(minWidth: 56, minHeight: 28, maxHeight: 28)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.14))
                                        .matchedGeometryEffect(id: "selection", in: pill)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(segment.count == 1 ? String(localized: "1 server") : String(localized: "\(segment.count) servers"))
                    .accessibilityLabel("\(segment.rawTitle), \(segment.count)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
            .fixedSize()
            .animation(reduceMotion ? nil : .rxMove, value: active)
            .help(String(localized: "Show every server, or one group's"))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Group"))
            .onAppear { reconcile(segments) }
            .onChange(of: segments) { reconcile($0) }
        }
    }

    private func reconcile(_ segments: [Segment]) {
        if !segments.isEmpty, !segments.contains(where: { $0.filter == filterStore.selection }) {
            filterStore.selection = .all
        }
    }
}

private struct HomeContent: View {
    let search: String

    @EnvironmentObject var store: TamioStore
    @ObservedObject private var filterStore = HomeGroupFilterStore.shared
    @State private var selection: RDMachine.ID?
    /// The page's width, to share it between the cards and the inspector.
    @State private var pageWidth: CGFloat = 900

    var filter: HomeGroupFilter {
        filterStore.selection.resolved(in: store.machineGroup.machines)
    }

    /// The inspector gives up width before the cards go too narrow.
    var inspectorWidth: CGFloat {
        min(ServerInspector.width, max(300, pageWidth - StatusCard.minimumWidth - RX.Space.s4 * 2))
    }

    var machines: [RDMachine] {
        let current = filter
        let shown = store.machineGroup.machines.filter { current.includes($0) }
        let needle = search.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty ? shown : shown.filter { $0.isQualifiedForSearch(text: needle) }
    }

    var body: some View {
        // The inspector is a panel beside the cards under the toolbar, never
        // under it: the toolbar's search and New Server stay on their own row
        // and take every click.
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                content
                    .padding(.horizontal, RX.Space.s4)
                    .padding(.top, RX.Space.s1)
                    .padding(.bottom, RX.Space.s6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: StatusCard.minimumWidth + RX.Space.s4 * 2, maxWidth: .infinity)
            if let selection, store.machineGroup.machines.contains(where: { $0.id == selection }) {
                ServerInspector(machine: selection) { self.selection = nil }
                    .frame(width: inspectorWidth)
                    // Only the panel moves: the cards take their new width at
                    // once, not frame by frame, so they never stutter.
                    .transition(.move(edge: .trailing).combined(with: .opacity)
                        .animation(.spring(response: 0.3, dampingFraction: 0.9)))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { pageWidth = $0 }
        .background {
            // Esc closes the inspector.
            if selection != nil {
                Button("Close Inspector") { selection = nil }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
    }

    @ViewBuilder var content: some View {
        if store.machineGroup.machines.isEmpty {
            EmptyStateView(
                "Save a server to reach it in one click",
                systemImage: "server.rack",
                message: "Its live load, CPU, memory, disk and traffic show here, and it opens a terminal or files in one click.",
                actionTitle: "New Server"
            ) {
                AppRouter.shared.presentNewServer = true
            }
            .frame(maxWidth: .infinity)
            .rxCard()
        } else if machines.isEmpty {
            EmptyStateView(noMatchTitle, systemImage: "magnifyingglass")
                .rxCard()
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: StatusCard.minimumWidth, maximum: StatusCard.maximumWidth), spacing: RX.Space.s3, alignment: .top)],
                alignment: .leading,
                spacing: RX.Space.s3
            ) {
                ForEach(machines) { machine in
                    // A click shows the card's server in the panel; the panel's
                    // close button and Esc put it away.
                    StatusCard(machine: machine.id, selected: selection == machine.id) {
                        if selection != machine.id { selection = machine.id }
                    }
                }
            }
        }
    }

    var noMatchTitle: LocalizedStringKey {
        switch filter {
        case .all: return "No servers match “\(search)”"
        case .ungrouped: return "No servers in no group match “\(search)”"
        case let .group(name): return "No servers in \(name) match “\(search)”"
        }
    }
}
