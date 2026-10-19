//
//  TamioApp.swift
//  Tamio (macOS)
//
//  Created by Lakr Aream on 2022/2/8.
//

import AppKit
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
            Button("Settings…") { AppRouter.shared.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("New Server…") { AppRouter.shared.presentNewServer = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Terminals…") { AppRouter.shared.openTerminals() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Home") { AppRouter.shared.route = .home }
                .keyboardShortcut("1", modifiers: .command)
            Button("Servers") { AppRouter.shared.route = .servers }
                .keyboardShortcut("2", modifiers: .command)
            Button("Identities") { AppRouter.shared.route = .identities }
                .keyboardShortcut("3", modifiers: .command)
            Button("Snippets") { AppRouter.shared.route = .snippets }
                .keyboardShortcut("4", modifiers: .command)
            Button("Port Forward") { AppRouter.shared.route = .portForward }
                .keyboardShortcut("5", modifiers: .command)
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
        if let window = Mac.mainWindow, window.isVisible {
            Mac.activate(window: window)
            return
        }
        Mac.activate()
        openWindow?(id: id)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once at launch on the main thread; read there ever after.
    @MainActor private(set) static var shared: AppDelegate!

    override init() {
        super.init()
        debugPrint("\(self) \(#function)")
        assert(AppDelegate.shared == nil, "duplicated init of AppDelegate")
        AppDelegate.shared = self

        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(windowStatusWatcher),
            userInfo: nil,
            repeats: true
        )
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
    }

    func applicationDidFinishLaunching(_: Notification) {
        AppearancePreference.applyStored()
        Mac.mayTerminate = { AppDelegate.shared.mayTerminate() }
        Mac.openApp = { MainWindow.show() }
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

    /// With every window closed and a server in the menu bar, Tamio leaves the
    /// Dock and stays in the menu bar.
    @objc
    func windowStatusWatcher() {
        Mac.setAccessory(!Mac.hasVisibleWindow && MenubarTool.shared.hasCat)
    }
}
