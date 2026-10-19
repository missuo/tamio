//
//  MainView.swift
//  Tamio (macOS)
//
//  The main window: a native sidebar (Liquid Glass on macOS 26) over a translucent
//  window, and the content column.
//

import MachineStatusView
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

    var body: some View {
        window
            // Open Tamio from the menu bar, with the window closed, opens it again.
            .onAppear {
                MainWindow.openWindow = openWindow
                AppDelegate.shared?.windowDidAppear()
            }
    }

    private var window: some View {
        NavigationSplitView(columnVisibility: $router.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: RX.sidebarWidth, max: 280)
        } detail: {
            // Pages cross-fade with a slight rise, so the eye follows the change
            // of place instead of seeing the content column jump.
            ZStack {
                RXWindowBackground()
                    .ignoresSafeArea()
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
                        .opacity(router.route == .settings ? 1 : 0)
                        .animation(router.route == .settings ? .easeOut(duration: 0.16) : nil, value: router.route == .settings)
                        .allowsHitTesting(router.route == .settings)
                        .accessibilityHidden(router.route != .settings)
                }
                SessionPages(route: router.route)
            }
            .onChange(of: router.route == .settings) { shown in
                // Before macOS 26 its toolbar and search field cannot be taken
                // out of the window while it is kept, so there it is not kept.
                if shown, #available(macOS 26.0, *) { settingsOpened = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.2), value: router.route.isSession ? nil : router.route)
            // Set here, outside the page transition, so the toolbar never falls
            // back to its opaque background while one page fades into another.
            .rxClearToolbar()
        }
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
        opacity(active ? 1 : 0)
            // The page coming in fades up quickly; the one going out leaves at
            // once, so two layouts never mix on screen.
            .animation(active ? .easeOut(duration: 0.16) : nil, value: active)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
            .environment(\.isActivePage, active)
    }
}
