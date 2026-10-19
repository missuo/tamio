//
//  SidebarView.swift
//  Tamio (macOS)
//
//  Home · Manage · Sessions (one row per server with open sessions, and under
//  it a row per terminal when it has several; the page's toolbar switches
//  between its Terminal, Files and Monitor), with Settings
//  pinned to the bottom-left corner. Drawn to the measurements of an AppKit
//  source list, which UIKit's sidebar list does not share.
//

import MachineStatusView
import TamioDesign
import TamioModule
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: TamioStore
    @ObservedObject var router = AppRouter.shared
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var transfers = FileTransferManager.shared

    /// A place (Home, Servers…) or a server with open sessions. Selecting a
    /// server shows the tool it showed last; the toolbar switcher changes tools.
    enum Item: Hashable {
        case place(Route)
        case owner(SessionOwner)
        /// One of a server's terminals, when it has several.
        case terminal(UUID)
    }

    var selection: Binding<Item?> {
        Binding(get: {
            if case let .terminal(id) = router.route, let owner = router.owner(of: router.route),
               router.terminals(of: owner).count > 1
            {
                return .terminal(id)
            }
            if router.route.isSession {
                return router.owner(of: router.route).map(Item.owner)
            }
            return .place(router.route)
        }, set: { item in
            switch item {
            case let .place(route): router.route = route
            case let .owner(owner): router.show(owner)
            case let .terminal(id): router.route = .terminal(id)
            case nil: break
            }
        })
    }

    /// Changes whenever a session opens or closes; drives the row animation.
    private var sessionIDs: [UUID] {
        terminals.sessionContexts.map(\.id) + transfers.transfers.map(\.id) + monitors.sessions.map(\.id)
    }

    var body: some View {
        let metrics = SidebarMetrics.current
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                place(.home, "Home", systemImage: "house")

                SidebarHeader("Manage")
                place(.servers, "Servers", systemImage: "server.rack", badge: store.machineGroup.count)
                place(.identities, "Identities", systemImage: "person.badge.key", badge: store.identityGroup.shared.count)
                place(.snippets, "Snippets", systemImage: "chevron.left.forwardslash.chevron.right", badge: store.snippetGroup.count)
                place(.portForward, "Port Forward", systemImage: "arrow.left.arrow.right", badge: store.portForwardGroup.count)

                if !sessionIDs.isEmpty {
                    SidebarHeader("Sessions")
                    ForEach(router.openOwners, id: \.self) { owner in
                        SidebarRow(isSelected: selection.wrappedValue == .owner(owner)) {
                            selection.wrappedValue = .owner(owner)
                        } label: {
                            OwnerSidebarRow(owner: owner)
                        }
                        .accessibilityLabel(ownerTitle(owner))
                        .transition(.opacity)
                        // Several terminals: one row each, under the server.
                        let terminals = router.terminals(of: owner)
                        if terminals.count > 1 {
                            ForEach(terminals) { context in
                                SidebarRow(isSelected: selection.wrappedValue == .terminal(context.id)) {
                                    selection.wrappedValue = .terminal(context.id)
                                } label: {
                                    TerminalSidebarRow(context: context)
                                }
                                .accessibilityLabel(context.sidebarTitle)
                                .transition(.opacity)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, SidebarMetrics.inset)
        }
        .animation(.easeInOut(duration: 0.25), value: sessionIDs)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Settings stays pinned to the bottom-left corner, drawn exactly like
            // the rows above; a new version's notice sits just over it.
            VStack(alignment: .leading, spacing: RX.Space.s2) {
                KeyNotice()
                UpdateNotice()
                place(.settings, "Settings", systemImage: "gearshape")
                    .help(Text("Settings (⌘,)"))
                    .frame(height: 48, alignment: .top)
            }
            .padding(.horizontal, SidebarMetrics.inset)
        }
        .environment(\.sidebarMetrics, metrics)
    }

    /// A session row's name: the server's, or the Quick Connect command's.
    private func ownerTitle(_ owner: SessionOwner) -> String {
        switch owner {
        case let .server(id): return store.machineGroup[id].name
        case let .command(id): return terminals.sessionContexts.first { $0.id == id }?.displayName ?? String(localized: "Terminal")
        }
    }

    private func place(_ route: Route, _ title: LocalizedStringKey, systemImage: String, badge: Int = 0) -> some View {
        SidebarRow(isSelected: selection.wrappedValue == .place(route)) {
            selection.wrappedValue = .place(route)
        } label: {
            SidebarLabel(title, systemImage: systemImage, badge: badge)
        }
        .accessibilityLabel(Text(title))
    }
}

// MARK: - Rows

/// The sizes AppKit gives a source list, for each "Sidebar icon size" of System
/// Settings. UIKit's sidebar list is taller and highlights the selection in the
/// accent colour, so the rows are drawn here to the Mac's measurements.
struct SidebarMetrics: Equatable {
    var rowHeight: CGFloat
    var fontSize: CGFloat
    var iconSize: CGFloat
    /// From the leading edge of the row to the centre of its icon.
    var iconCenter: CGFloat
    /// From the leading edge of the row to its title.
    var titleLeading: CGFloat
    /// Where a row without an icon starts its text: the icons' leading edge.
    var nameLeading: CGFloat { iconCenter - iconSize / 2 }

    /// Rows stop this far from the edges of the sidebar.
    static let inset: CGFloat = 10

    static let small = SidebarMetrics(rowHeight: 25, fontSize: 10, iconSize: 15, iconCenter: 18.5, titleLeading: 36)
    static let medium = SidebarMetrics(rowHeight: 32, fontSize: 13, iconSize: 17, iconCenter: 19.25, titleLeading: 36.5)
    static let large = SidebarMetrics(rowHeight: 40, fontSize: 15, iconSize: 19.5, iconCenter: 20.25, titleLeading: 38.5)

    /// "Sidebar icon size" in System Settings › Appearance.
    static var current: SidebarMetrics {
        switch UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode") {
        case 1: return .small
        case 3: return .large
        default: return .medium
        }
    }
}

private struct SidebarMetricsKey: EnvironmentKey {
    static let defaultValue = SidebarMetrics.medium
}

private struct SidebarSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sidebarMetrics: SidebarMetrics {
        get { self[SidebarMetricsKey.self] }
        set { self[SidebarMetricsKey.self] = newValue }
    }

    /// Whether the sidebar row a view sits in is the selected one.
    var isSidebarRowSelected: Bool {
        get { self[SidebarSelectedKey.self] }
        set { self[SidebarSelectedKey.self] = newValue }
    }
}

/// One selectable row: the grey rounded highlight of a Mac source list, selected
/// on mouse down like one.
private struct SidebarRow<Label: View>: View {
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.sidebarMetrics) private var metrics

    var body: some View {
        label
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: metrics.rowHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.155))
                }
            }
            .contentShape(Rectangle())
            .environment(\.isSidebarRowSelected, isSelected)
            .onTapGesture(perform: select)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            // VoiceOver's press, which a tap gesture alone does not answer.
            .accessibilityAction { select() }
    }
}

extension View {
    /// The whole row as the hit area, so a context menu attached after this
    /// opens from a right-click anywhere on the row, not only on its text.
    fileprivate func sidebarRowShape(_ metrics: SidebarMetrics) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: metrics.rowHeight)
            .contentShape(Rectangle())
    }
}

/// Icon in the accent colour, title, and a count at the trailing edge.
struct SidebarLabel<Title: View>: View {
    let systemImage: String
    let badge: Int
    let title: Title
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.isSidebarRowSelected) private var isSelected

    init(systemImage: String, badge: Int = 0, @ViewBuilder title: () -> Title) {
        self.systemImage = systemImage
        self.badge = badge
        self.title = title()
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.iconSize))
                .foregroundStyle(.rxAccent)
                .frame(width: metrics.iconCenter * 2)
                .frame(width: metrics.titleLeading, alignment: .leading)
            title
                .font(.system(size: metrics.fontSize, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.primary.opacity(isSelected ? 0.5 : 0.4))
                    .padding(.trailing, 10)
            }
        }
    }
}

extension SidebarLabel where Title == Text {
    init(_ title: LocalizedStringKey, systemImage: String, badge: Int = 0) {
        self.init(systemImage: systemImage, badge: badge) { Text(title) }
    }
}

/// Above Settings when the keychain refused the master key: the store is
/// there but cannot be read or written until the key is handed over, which
/// otherwise looks like an app with nothing in it.
private struct KeyNotice: View {
    var body: some View {
        if !TamioStore.savesChanges {
            HStack(alignment: .top, spacing: RX.Space.s2) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.rxDanger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Servers can't be shown")
                        .font(.rxBodyStrong)
                        .foregroundStyle(.rxInk)
                    Text("Tamio couldn't read its key from your keychain. Quit Tamio, open it again, and click Allow when asked.")
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, RX.Space.s3)
            .padding(.vertical, RX.Space.s2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.rxDanger.opacity(0.12))
            )
            .accessibilityElement(children: .combine)
        }
    }
}

/// "Manage", "Sessions": the small grey heading over a group of rows.
private struct SidebarHeader: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.26))
            .padding(.leading, 4)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A server with open sessions (or a Quick Connect terminal): its name, with
/// no symbol before it so a long name has the room, then small symbols for
/// the tools that are open.
private struct OwnerSidebarRow: View {
    let owner: SessionOwner
    @EnvironmentObject var store: TamioStore
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.isSidebarRowSelected) private var isSelected

    private var routes: [Route] { AppRouter.shared.routes(of: owner) }

    private var title: String {
        switch owner {
        case let .server(id):
            let machine = store.machineGroup[id]
            return [machine.countryFlag, machine.name].compactMap { $0 }.joined(separator: " ")
        case let .command(id):
            return terminals.sessionContexts.first { $0.id == id }?.displayName ?? String(localized: "Terminal")
        }
    }

    private var openTools: [ServerTool] {
        ServerTool.allCases.filter { tool in
            routes.contains { route in
                switch (tool, route) {
                case (.terminal, .terminal), (.files, .transfer), (.monitor, .monitor): return true
                default: return false
                }
            }
        }
    }

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            RedactableText(title, redacted: store.machineRedacted == .all)
                .font(.system(size: metrics.fontSize, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, metrics.nameLeading)
            Spacer(minLength: 4)
            if case .server = owner {
                HStack(spacing: 3) {
                    ForEach(openTools) { tool in
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 10)
                .accessibilityHidden(true)
            }
        }
        .sidebarRowShape(metrics)
        // The whole name, for one too long for the row.
        .help(String(localized: "\(title) · \(openTools.map(\.title).joined(separator: ", ")) open"))
        .contextMenu { menu }
    }

    @ViewBuilder var menu: some View {
        if let terminal = AppRouter.shared.terminals(of: owner).first {
            Button("Duplicate Terminal") { terminal.duplicate() }
            Divider()
        }
        ForEach(routes, id: \.self) { route in
            switch route {
            case let .terminal(id):
                if let context = terminals.sessionContexts.first(where: { $0.id == id }) {
                    if context.closed { Button("Reconnect \(context.sidebarTitle)") { context.reconnect() } }
                    Button("Close \(context.sidebarTitle)") { TerminalSessionActions.close(context) }
                }
            case let .transfer(id):
                if let context = transfers.transfers.first(where: { $0.id == id }) {
                    Button("Close Files") { FileTransferSessionActions.close(context) }
                }
            case let .monitor(id):
                Button("Close Monitor") { MonitorCenter.shared.end(id) }
            default:
                EmptyView()
            }
        }
        if routes.count > 1 {
            Divider()
            Button("Close All") {
                Dialogs.requiresConfirmation(
                    message: String(localized: "Close everything open on \(title)?"),
                    confirmTitle: String(localized: "Close All"),
                    destructive: true
                ) { confirmed in
                    if confirmed { AppRouter.shared.closeAll(owner) }
                }
            }
        }
    }
}

/// One of a server's terminals, under the server's row: the shell's title.
private struct TerminalSidebarRow: View {
    @ObservedObject var context: TerminalManager.Context
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.isSidebarRowSelected) private var isSelected

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(context.closed ? Color.rxInkTertiary : Color.rxSuccess)
                .frame(width: 6, height: 6)
            Text(context.sidebarTitle)
                .font(.system(size: metrics.fontSize - 1, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .fixedSize()
                .help(context.navigationSubtitle.isEmpty ? context.sidebarTitle : context.navigationSubtitle)
            Spacer(minLength: 4)
        }
        // Under the server's name, a step in.
        .padding(.leading, metrics.nameLeading + RX.Space.s3)
        .sidebarRowShape(metrics)
        .contextMenu {
            Button("Duplicate Terminal") { context.duplicate() }
            if context.closed { Button("Reconnect") { context.reconnect() } }
            Divider()
            Button("Close Terminal") { TerminalSessionActions.close(context) }
        }
    }
}
