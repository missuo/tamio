//
//  TamioApp.swift
//  Tamio (macOS)
//
//  Created by Lakr Aream on 2022/2/8.
//

import AppKit
import Combine
import MachineStatusView
import SwiftUI
import TamioModule
import TamioTerminal

@main
struct TamioApp: App {
    @StateObject private var store = TamioStore.shared

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        #if DEBUG
            NSLog(CommandLine.arguments.joined(separator: "\n"))
        #endif
        // Before the store: it reads the master key as it loads.
        Mac.installLegacyKeyStore()
        _ = TamioStore.shared
        CloudSync.shared.preferences = SyncedSettings.all
        CloudSync.shared.start()
        // Every server card shows live status without opening a monitor.
        LiveStatusCenter.shared.start()
        // Agents reach the servers through the MCP server (Settings › MCP).
        AgentBridge.shared.start()
        // Release builds look for new versions (Sparkle) once a day.
        UpdateCenter.shared.start()

        // Shared file-transfer core lives in TamioModule; register the
        // platform UI handler it delegates to.
        FileTransferInterface.uiHandler = MacFileTransferUIHandler()

        NSLog("static main completed")
    }

    var body: some Scene {
        // One window: its title bar carries the toolbar, with no title, over
        // the window material the pages draw on.
        Window("Tamio", id: MainWindow.id) {
            MainView()
                .environmentObject(store)
                .frame(minWidth: MainWindow.minimumSize.width, minHeight: MainWindow.minimumSize.height)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            TamioCommands()
        }
    }
}

/// Menu commands: New Server, Settings (Settings is a sidebar destination), navigation.
struct TamioCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if UpdateCenter.shared.isSupported {
                Button("Check for Updates…") { UpdateCenter.shared.checkNow() }
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                MainWindow.show()
                AppRouter.shared.openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("New Server…") {
                MainWindow.show()
                AppRouter.shared.presentNewServer = true
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Terminals…") {
                MainWindow.show()
                AppRouter.shared.openTerminals()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Home") {
                MainWindow.show()
                AppRouter.shared.route = .home
            }
            .keyboardShortcut("1", modifiers: .command)
            Button("Servers") {
                MainWindow.show()
                AppRouter.shared.route = .servers
            }
            .keyboardShortcut("2", modifiers: .command)
            Button("Identities") {
                MainWindow.show()
                AppRouter.shared.route = .identities
            }
            .keyboardShortcut("3", modifiers: .command)
            Button("Snippets") {
                MainWindow.show()
                AppRouter.shared.route = .snippets
            }
            .keyboardShortcut("4", modifiers: .command)
            Button("Port Forward") {
                MainWindow.show()
                AppRouter.shared.route = .portForward
            }
            .keyboardShortcut("5", modifiers: .command)
            Divider()
        }
        CommandGroup(before: .windowList) {
            Button("Main Window") { MainWindow.show() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}

/// The main window: its size, and how it is brought back.
enum MainWindow {
    static let id = "main"

    /// The smallest the window may be: Home's cards beside the inspector,
    /// Settings' three columns, and the whole sidebar with Settings clear of
    /// the bottom edge.
    static let minimumSize = CGSize(width: 960, height: 640)

    /// SwiftUI's way of opening the window, kept by the view that lives in
    /// it, for the times it has been closed.
    @MainActor static var openWindow: OpenWindowAction?

    /// Brings the main window forward, reopening it if it was closed.
    @MainActor static func show() {
        if let window = Mac.mainWindow, window.isVisible || window.isMiniaturized {
            Mac.activate(window: window)
            AppDelegate.shared?.windowDidAppear()
            return
        }
        Mac.activate()
        if let openWindow {
            openWindow(id: id)
        } else if let window = Mac.mainWindow {
            window.makeKeyAndOrderFront(nil)
        }
        AppDelegate.shared?.windowDidAppear()
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once at launch on the main thread; read there ever after.
    @MainActor private(set) static var shared: AppDelegate!
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        debugPrint("\(self) \(#function)")
        assert(AppDelegate.shared == nil, "duplicated init of AppDelegate")
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_: Notification) {
        AppearancePreference.applyStored()
        Mac.mayTerminate = { AppDelegate.shared.mayTerminate() }
        Mac.openApp = { MainWindow.show() }
        observeWindows()
        MenubarTool.shared.restore()
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAMIO_PREVIEW_TERMINAL"] != nil,
               let command = SSHCommandReader(command: "ssh demo@203.0.113.10")
            {
                AppRouter.shared.openTerminal(command: command)
                AppRouter.shared.route = .terminal(TerminalManager.shared.sessionContexts.last!.id)
            }
            // "colors" opens Settings there; "general,colors" goes on to the second.
            if let categories = ProcessInfo.processInfo.environment["TAMIO_PREVIEW_SETTINGS"]?.split(separator: ",").map(String.init) {
                for (index, category) in categories.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 2) {
                        // "@terminal" leaves Settings for the preview terminal.
                        if category == "@terminal", let session = TerminalManager.shared.sessionContexts.last {
                            AppRouter.shared.route = .terminal(session.id)
                        } else {
                            AppRouter.shared.openSettings(category)
                        }
                    }
                }
            }
            // "key=value" makes that edit six seconds in and takes it back ten later.
            if let pair = ProcessInfo.processInfo.environment["TAMIO_PREVIEW_EDIT"]?.split(separator: "=", maxSplits: 1).map(String.init), pair.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    let old = ConfigBenchmark.value(pair[0])
                    ConfigBenchmark.edit(pair[0], pair[1])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { ConfigBenchmark.edit(pair[0], old) }
                }
            }
            if ProcessInfo.processInfo.environment["TAMIO_PREVIEW_MENUBAR"] != nil {
                MenubarTool.shared.showPreview()
            }
            Bench.runIfRequested()
        #endif
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool { true }

    /// Closing the window leaves Tamio running in the background so MCP
    /// clients, port forwards and open terminals stay connected, and reopening
    /// the window is immediate. Only Quit terminates the process.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    /// Open Tamio from the menu bar, or a click on the Dock icon, brings the
    /// window back when it was closed.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainWindow.show() }
        return false
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        if let mayTerminate = Mac.mayTerminate, !mayTerminate() { return .terminateCancel }
        return .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        AgentSocket.shared.stop()
    }

    /// Set once the user agreed to quit, so the quit that follows goes through.
    @MainActor private var quitConfirmed = false

    /// Asked when the app is about to quit. With terminals open, the answer
    /// is no for now, and the question goes to the user.
    @MainActor func mayTerminate() -> Bool {
        // The question was answered; this is the quit that follows it.
        if quitConfirmed { return true }
        guard !TerminalManager.shared.sessionContexts.isEmpty else { return true }
        if TamioStore.shared.disableConformation {
            TerminalManager.shared.closeAll()
            return true
        }
        Dialogs.requiresConfirmation(
            message: String(localized: "Quit Tamio?"),
            informative: String(localized: "Open terminal sessions will be closed."),
            confirmTitle: String(localized: "Quit"),
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            MainActor.assumeIsolated {
                self.quitConfirmed = true
                TerminalManager.shared.closeAll()
                Mac.terminate()
            }
        }
        return false
    }

    // MARK: - Window lifecycle and background residency

    private func observeWindows() {
        let center = NotificationCenter.default
        center.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] notification in
                guard let window = notification.object as? NSWindow, Mac.isOrdinaryWindow(window) else { return }
                self?.windowDidAppear()
            }
            .store(in: &cancellables)

        center.publisher(for: NSWindow.didDeminiaturizeNotification)
            .sink { [weak self] notification in
                guard let window = notification.object as? NSWindow, Mac.isOrdinaryWindow(window) else { return }
                self?.windowDidAppear()
            }
            .store(in: &cancellables)

        center.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow, Mac.isOrdinaryWindow(window) else { return }
                if !Mac.hasVisibleWindow(excluding: window) {
                    self.enterBackgroundResidency(closing: window)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.updateWindowStatus()
                }
            }
            .store(in: &cancellables)

        TransferQueue.shared.$jobs
            .sink { [weak self] _ in
                guard let self, !Mac.hasVisibleWindow, TransferQueue.shared.active.isEmpty else { return }
                FileTransferManager.shared.closeAll()
            }
            .store(in: &cancellables)
    }

    /// Resumes window-bound background polling when the main window is shown.
    func windowDidAppear() {
        LiveStatusCenter.shared.setWindowVisible(true)
        updateWindowStatus()
    }

    /// Releases window-only resources when the last window closes while keeping
    /// MCP, the store, port forwards and open terminal shells alive.
    private func enterBackgroundResidency(closing: NSWindow?) {
        for context in TerminalManager.shared.sessionContexts {
            context.termInterface.setActive(false)
        }
        LiveStatusCenter.shared.setWindowVisible(false)
        MonitorCenter.shared.closeAll()
        if TransferQueue.shared.active.isEmpty {
            FileTransferManager.shared.closeAll()
        }
        Mac.setAccessory(!Mac.hasVisibleWindow(excluding: closing) && MenubarTool.shared.hasCat)
    }

    /// With every window closed and a server in the menu bar, Tamio leaves the
    /// Dock and stays in the menu bar; otherwise its Dock icon stays for reopen.
    func updateWindowStatus() {
        let visible = Mac.hasVisibleWindow
        LiveStatusCenter.shared.setWindowVisible(visible)
        Mac.setAccessory(!visible && MenubarTool.shared.hasCat)
    }
}
