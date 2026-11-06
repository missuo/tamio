//
//  MainView.swift
//  Tamio (macOS)
//
//  The main window: a native sidebar (Liquid Glass on macOS 26) over a translucent
//  window, and the content column.
//

import MachineStatusView
import TamioDesign
import TamioModule
import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: TamioStore
    @ObservedObject var router = AppRouter.shared

    @State private var openLicenseAgreement = false
    @Environment(\.openWindow) private var openWindow
    /// Settings is built when it is first opened and kept from then on: its
    /// categories are many rows each, and coming back shows what is there.
    @State private var settingsOpened = false
    @AppStorage(RXGlass.key) private var glass = true
    @State private var windowWidth: CGFloat = MainWindow.minimumSize.width

    var body: some View {
        window
            // The shared server views (cards, table, inspector) act through these.
            .environment(\.serverActions, .mac)
            .environment(\.rxGlass, glass)
            // Open Tamio from the menu bar, with the window closed, opens it again.
            .onAppear {
                MainWindow.openWindow = openWindow
                AppDelegate.shared?.windowDidAppear()
            }
    }

    private var window: some View {
        // The sidebar stays where it is, a panel at the leading edge; the
        // content lies over it and its leading edge slides: across the
        // sidebar to fill the window, or back to show it. The toggle is the
        // toolbar's first item and never moves.
        ZStack(alignment: .topLeading) {
            RXWindowBackground()
                .ignoresSafeArea()
            SidebarPanel()
            detail
                .padding(.leading, router.sidebarOpen ? MainWindow.sidebarSpan : 0)
                // The width the content has with the sidebar open, whatever
                // it has now: tables and grids choose their columns from it,
                // so showing or hiding the sidebar widens or narrows them
                // without a column coming or going.
                .environment(\.rxOpenWidth, max(0, windowWidth - MainWindow.sidebarSpan))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if width != windowWidth { windowWidth = width }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { SidebarToggle() }
                .rxPlain()
        }
        .rxClearToolbar()
        // No minimum frame of its own: the window cannot be smaller than
        // MainWindow.minimumSize (the scene's restriction, and AppKit's), and
        // content held to a minimum the window sits exactly at makes Catalyst
        // drop the toolbar for the in-window navigation bars.
        .overlay {
            if store.globalProgressInPresent {
                ProgressHUD()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.globalProgressInPresent)
        // New / Edit Server: a dialog over the dimmed window.
        .overlay {
            if let target = router.serverEditor {
                ZStack {
                    Color.rxScrim
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { NotificationCenter.default.post(name: .serverEditorWantsClose, object: nil) }
                        .transition(.opacity)
                    ServerEditorDialog(target: target)
                        .id(target)
                        .environmentObject(TamioStore.shared)
                        .padding(RX.Space.s6)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: router.serverEditor)
        .sheet(isPresented: $openLicenseAgreement) {
            AgreementSheet()
        }
        .onAppear {
            onMainThread(delay: 0.5) {
                if !store.licenseAgreed { openLicenseAgreement = true }
            }
        }
    }

    /// The pages, on a backdrop of their own that covers the sidebar as the
    /// content's edge slides over it.
    private var detail: some View {
        ZStack {
            RXWindowBackground()
                .ignoresSafeArea()
            ZStack {
                // Places (Home, Servers, Settings…) cross-fade with a slight rise,
                // so the eye follows the change of place.
                if !router.route.isSession, router.route != .settings {
                    content
                        .id(router.route)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity
                        ))
                }
                if settingsOpened || router.route == .settings {
                    // Told directly, not through the environment: a change of
                    // environment reaches every row of every category.
                    SettingsView(active: router.route == .settings)
                        .keepsSize(whileHidden: router.route != .settings)
                        .opacity(router.route == .settings ? 1 : 0)
                        .animation(router.route == .settings ? .easeOut(duration: 0.16) : nil, value: router.route == .settings)
                        .allowsHitTesting(router.route == .settings)
                        .accessibilityHidden(router.route != .settings)
                }
                SessionPages(route: router.route)
            }
            // Pages scroll up under the toolbar, which has neither a
            // background nor capsules round its buttons: what scrolls fades
            // out as it reaches the toolbar and is never drawn behind it.
            .mask { ToolbarEdgeMask() }
        }
        .onChange(of: router.route == .settings) { shown in
            // Before macOS 26 its toolbar and search field cannot be taken
            // out of the window while it is kept, so there it is not kept.
            if shown, #available(macOS 26.0, *) { settingsOpened = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pausesHitTestingWhileSidebarSlides()
        .animation(.easeOut(duration: 0.2), value: router.route.isSession ? nil : router.route)
        // Set here, outside the page transition, so the toolbar never falls
        // back to its opaque background while one page fades into another.
        .rxClearToolbar()
    }

    @ViewBuilder var content: some View {
        switch router.route {
        case .home:
            HomeView()
        case .servers:
            ServersView()
        case .identities:
            IdentitiesView()
        case .snippets:
            SnippetsView()
        case .portForward:
            PortForwardView()
        case .settings, .terminal, .monitor, .transfer:
            EmptyView()
        }
    }
}

/// Every open terminal, file browser and monitor stays mounted; the route only
/// decides which one is visible. Switching between a server's Terminal, Files
/// and Monitor (or between servers) is then a change of visibility, with no
/// page or terminal surface rebuilt and scroll positions kept.
private struct SessionPages: View {
    let route: Route
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var monitors = MonitorCenter.shared

    var body: some View {
        ZStack {
            ForEach(terminals.sessionContexts) { context in
                TerminalPage(context: context)
                    .sessionPage(active: route == .terminal(context.id))
            }
            ForEach(transfers.transfers) { context in
                FileTransferPage(context: context, active: route == .transfer(context.id))
                    .sessionPage(active: route == .transfer(context.id))
            }
            ForEach(monitors.sessions) { session in
                MonitorPage(session: session)
                    .sessionPage(active: route == .monitor(session.id))
            }
        }
    }
}

private extension View {
    func sessionPage(active: Bool) -> some View {
        keepsSize(whileHidden: !active)
            .opacity(active ? 1 : 0)
            // The page coming in fades up quickly; the one going out leaves at
            // once, so two layouts never mix on screen.
            .animation(active ? .easeOut(duration: 0.16) : nil, value: active)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
            .environment(\.isActivePage, active)
    }
}

/// A page kept out of sight keeps the size it had when it was last shown.
/// Otherwise every frame of a sidebar slide or a window resize lays it out
/// again: a terminal re-wraps its text and resizes the remote shell, and
/// Settings measures its hundreds of rows. Shown again, it takes the size of
/// the window once.
private struct KeepsSizeWhileHidden: ViewModifier {
    let hidden: Bool
    @State private var size: CGSize?

    func body(content: Content) -> some View {
        content
            .frame(width: hidden ? size?.width : nil, height: hidden ? size?.height : nil)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { new in
                if !hidden { size = new }
            }
            // Takes exactly what it is given, so a page held larger than the
            // window overflows out of sight instead of widening the stack,
            // which would push the sidebar and the page in view off the
            // window's edges. Both bounds matter: a frame with only a maximum
            // takes its child's size when the child is the larger.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension View {
    func keepsSize(whileHidden hidden: Bool) -> some View {
        modifier(KeepsSizeWhileHidden(hidden: hidden))
    }
}

/// Clear over the toolbar, then a short fade, then the page: the band the
/// toolbar takes is the top safe-area inset.
private struct ToolbarEdgeMask: View {
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Color.clear.frame(height: proxy.safeAreaInsets.top)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 12)
                Color.black
            }
            .ignoresSafeArea()
        }
    }
}

/// Shows and hides the sidebar, from the start of the toolbar, beside the
/// window's buttons, where it stays whether the sidebar is open or not.
struct SidebarToggle: View {
    var body: some View {
        Button {
            AppRouter.shared.toggleSidebar()
        } label: {
            // The system's own symbol, the one icon not from Tamio's set: the
            // window's sidebar button reads best as the Mac draws it.
            Label("Toggle Sidebar", systemImage: "sidebar.leading")
        }
        .help(Text("Show or hide the sidebar (⌃⌘S)"))
    }
}

/// The sidebar: a panel inset from the window's leading edge, under the
/// window's buttons and the toggle, at a fixed width. It does not move; when
/// it is hidden the content lies over it.
private struct SidebarPanel: View {
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var slide = SidebarSlide.shared

    var body: some View {
        SidebarView()
            .frame(width: RX.sidebarWidth)
            .frame(maxHeight: .infinity)
            // Up past the toolbar to just under the window's top edge, so the
            // window's buttons and the toggle sit on the panel.
            .background {
                RXCardBackground(radius: RX.Radius.card)
                    .padding(.top, MainWindow.sidebarInset)
                    .ignoresSafeArea(.container, edges: .top)
            }
            .padding(.bottom, MainWindow.sidebarInset)
            .padding(.leading, MainWindow.sidebarInset)
            // Covered by the content while hidden; out of sight once it is.
            .opacity(router.sidebarOpen || slide.sliding ? 1 : 0)
            .allowsHitTesting(router.sidebarOpen && !slide.sliding)
            .accessibilityHidden(!router.sidebarOpen)
    }
}
