//
//  HomeView.swift
//  Tamio (macOS)
//
//  Start page: every server's live status card in a dense grid straight under
//  the toolbar (the group switcher in its middle, New Server and search at its
//  trailing end, no title row), and beside them the inspector of the card
//  that is selected.
//

import MachineStatusView
import SwiftUI
import TamioDesign
import TamioModule

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
            ) {} trailing: {}
            // The groups at the toolbar's leading edge, on the row of New and
            // search, lined up with the cards.
            .rxPlainToolbar {
                ToolbarItem(placement: .navigation) { LeadingGroupSwitcher() }
            }
    }
}

/// The group switcher, lined up with the cards' leading edge: the toolbar
/// places it after the sidebar button, which with the sidebar open is over
/// the sidebar, so it is moved along to where the cards start, and back to
/// the button as the sidebar hides. The toolbar item keeps one width (the
/// switcher and the room it moves in) and only what is drawn in it moves, so
/// the toolbar is not laid out again at every frame of the slide.
private struct LeadingGroupSwitcher: View {
    @ObservedObject private var router = AppRouter.shared
    /// The item's leading edge in the window, where the toolbar put it. Kept
    /// from the last time Home was shown: the toolbar puts it in the same
    /// place each time, and measured afresh it is known only a frame late, so
    /// the switcher showed at the toolbar's edge and then moved across.
    @State private var origin: CGFloat? = Self.lastOrigin
    @MainActor private static var lastOrigin: CGFloat?

    var body: some View {
        // The cards start the page's margin in from the content's edge.
        let target = MainWindow.sidebarSpan + RX.Space.s4
        let room = origin.map { max(0, target - $0) } ?? 0
        HomeGroupSwitcher()
            .padding(.trailing, room)
            .offset(x: router.sidebarOpen ? room : 0)
            .animation(SidebarSlide.animation, value: router.sidebarOpen)
            // Not seen until it is in its place, the first time.
            .opacity(origin == nil ? 0 : 1)
            // Read where the item is, not where its content was moved to.
            .background(WindowOriginReader { x in
                guard x != origin else { return }
                Self.lastOrigin = x
                // Put there at once: the page's arrival animates, this must not.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { origin = x }
            })
    }
}

/// Tells where in its window the view it backs starts.
private struct WindowOriginReader: NSViewRepresentable {
    let changed: (CGFloat) -> Void

    final class Probe: NSView {
        var changed: ((CGFloat) -> Void)?
        private var last: CGFloat?

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        private func report() {
            guard window != nil else { return }
            let x = convert(bounds.origin, to: nil).x.rounded()
            guard x != last else { return }
            last = x
            DispatchQueue.main.async { [weak self] in self?.changed?(x) }
        }
    }

    func makeNSView(context _: Context) -> Probe {
        let probe = Probe()
        probe.changed = changed
        return probe
    }

    func updateNSView(_ probe: Probe, context _: Context) {
        probe.changed = changed
    }
}

private struct HomeContent: View {
    let search: String

    @EnvironmentObject var store: TamioStore
    @State private var selection: RDMachine.ID?
    /// The inspector's width, worked out from the page's. Kept rather than
    /// the page's width so the page is not drawn again for every point the
    /// window or the sidebar moves: it changes only when the inspector would.
    @State private var inspectorWidth: CGFloat = ServerInspector.width

    /// The inspector gives up width before the cards go too narrow.
    static func inspectorWidth(forPage width: CGFloat) -> CGFloat {
        min(ServerInspector.width, max(300, width.rounded() - StatusCardMetrics.minimumWidth - RX.Space.s4 * 2))
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
                    .transformEnvironment(\.rxOpenWidth) { $0 -= RX.Space.s4 * 2 }
            }
            .frame(minWidth: StatusCardMetrics.minimumWidth + RX.Space.s4 * 2, maxWidth: .infinity)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let fitted = Self.inspectorWidth(forPage: width)
            if fitted != inspectorWidth { inspectorWidth = fitted }
        }
        .background {
            // Esc closes the inspector.
            if selection != nil {
                Button("Close Inspector") { selection = nil }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
    }

    var content: some View {
        ServerCardsGrid(search: search, selection: $selection) { machine in
            ServerContextMenu(machine: machine, includesTools: false)
        } context: { machine in
            ServerContextMenu(machine: machine)
        }
    }
}
