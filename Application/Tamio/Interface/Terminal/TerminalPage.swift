//
//  TerminalPage.swift
//  Tamio (macOS)
//
//  A terminal inside the main window: the Terminal · Files · Monitor switcher,
//  text size, the snippets panel and Reconnect. The sidebar lists a server's
//  terminals, and its menu duplicates and closes them. Status bar: the
//  endpoint, then live figures while monitored.
//

import MachineStatusView
import TamioModule
import TamioTerminal
import SwiftUI

struct TerminalPage: View {
    @ObservedObject var context: TerminalManager.Context
    @EnvironmentObject var store: TamioStore

    @State private var interfaceToken = UUID()
    @Environment(\.isActivePage) private var isActive
    /// The snippets panel beside the terminal, shown or hidden for every terminal.
    @AppStorage(TerminalSnippetPanel.shownKey) private var snippetsShown = false

    var body: some View {
        HStack(alignment: .top, spacing: RX.Space.s3) {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if context.closed {
                        disconnectedBanner
                    }
                    surface
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // No backdrop of our own: Ghostty paints its background with
                // `background-opacity`, so a translucent terminal shows the window
                // material underneath instead of an opaque fill.
                .clipShape(RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous))
                // The terminal ends level with the sidebar's Settings row; the
                // status line takes the margin under it.
                TerminalStatusBar(context: context)
                    .frame(height: RX.Space.s6)
            }
            if snippetsShown {
                TerminalSnippetPanel(context: context) { snippetsShown = false }
                    .frame(width: TerminalSnippetPanel.width)
                    .padding(.bottom, RX.Space.s6)
                    // Only the panel moves: the terminal takes its new width at
                    // once, not frame by frame, so its text never stutters.
                    .transition(.move(edge: .trailing).combined(with: .opacity)
                        .animation(.spring(response: 0.3, dampingFraction: 0.9)))
            }
        }
        .padding(.horizontal, RX.Space.s6)
        .padding(.top, RX.Space.s3)
        .pageChrome()
        // Closing and duplicating are in the sidebar's menu.
        .pageToolbar(
            primary: context.closed
                ? ToolbarAction("Reconnect", systemImage: "arrow.clockwise", primary: true) { context.reconnect() }
                : nil,
            trailingMetrics: .controlGroup
        ) {
            EmptyView()
        } trailing: {
            Group {
                Button {
                    store.terminalFontSize -= 1
                } label: {
                    Label("Smaller Text", systemImage: "textformat.size.smaller")
                }
                .disabled(store.terminalFontSize <= 4)
                .keyboardShortcut("-", modifiers: .command)
                Button {
                    store.terminalFontSize += 1
                } label: {
                    Label("Larger Text", systemImage: "textformat.size.larger")
                }
                .disabled(store.terminalFontSize >= 30)
                .keyboardShortcut("+", modifiers: .command)
            }
            .help(String(localized: "Text Size"))
            Toggle(isOn: $snippetsShown) {
                Label("Snippets", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .help(String(localized: "Show or hide the snippets panel (⌥⌘S)"))
        }
        .serverToolSwitcher(
            machine: context.remoteType == .machine && context.machine.isNotPlaceholder() ? context.machine.id : nil,
            current: .terminal
        )
        .onAppear {
            context.interfaceToken = interfaceToken
            context.termInterface.setActive(isActive)
        }
        .onChange(of: isActive) { active in
            context.termInterface.setActive(active)
        }
    }

    @ViewBuilder var surface: some View {
        if context.interfaceToken == interfaceToken {
            context.termInterface
                .onChange(of: store.terminalFontSize) { newValue in
                    context.termInterface.setTerminalFontSize(with: newValue)
                }
                .onAppear {
                    context.termInterface.setTerminalFontSize(with: store.terminalFontSize, preferConfigured: true)
                }
        } else {
            EmptyStateView(
                "Terminal moved to another window",
                systemImage: "macwindow",
                actionTitle: "Bring Back Here"
            ) {
                context.interfaceToken = interfaceToken
            }
            .environment(\.colorScheme, .dark)
            .background(Color.rxTerminalBackground)
        }
    }

    var disconnectedBanner: some View {
        HStack(spacing: RX.Space.s2) {
            Text("Connection closed")
                .foregroundStyle(.rxTerminalForeground)
            Spacer()
        }
        .font(.rxBody)
        .padding(.horizontal, RX.Space.s3)
        .frame(height: 36)
        .background(Color.black.opacity(0.35))
    }
}

/// State, user@host:port, live CPU and memory while a monitor is open, font size.
private struct TerminalStatusBar: View {
    @ObservedObject var context: TerminalManager.Context
    @ObservedObject var monitors = MonitorCenter.shared
    @EnvironmentObject var store: TamioStore

    var body: some View {
        HStack(spacing: RX.Space.s4) {
            RedactableText(endpoint, redacted: store.machineRedacted != .none)
                .font(.rxCode)
            Spacer(minLength: RX.Space.s2)
            if let session = monitors.session(for: context.machine.id) {
                LiveFigures(session: session)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.rxInkSecondary)
        .padding(.horizontal, RX.Space.s1)
    }

    var endpoint: String {
        if let command = context.command { return command.command }
        return context.machine.getCommand(insertLeadingSSH: false)
    }

    private struct LiveFigures: View {
        @ObservedObject var session: MonitorSession
        var body: some View {
            if session.status.hasData {
                Text("CPU \(RXFormat.percent(Double(session.status.processor.summary.sumUsed)))%")
                Text("Mem \(RXFormat.percent(session.status.memoryUsedPercent))%")
                Text("↓ \(RXFormat.rateString(Double(session.status.totalReceivePerSecond))) ↑ \(RXFormat.rateString(Double(session.status.totalTransmitPerSecond)))")
            }
        }
    }
}

enum TerminalSessionActions {
    @MainActor
    static func close(_ context: TerminalManager.Context) {
        let manager = TerminalManager.shared
        if manager.sessionAlive(forContext: context.id) {
            Dialogs.requiresConfirmation(
                message: String(localized: "Close the session on \(context.displayName)?"),
                confirmTitle: String(localized: "Close Session"),
                destructive: true
            ) { confirmed in
                if confirmed { manager.closeSession(withContextID: context.id) }
            }
        } else {
            manager.closeSession(withContextID: context.id)
        }
    }
}

extension TerminalManager.Context {
    /// The server's name, or `user@host` for a Quick Connect session.
    var displayName: String {
        if remoteType == .machine { return machine.name }
        if let command { return "\(command.username)@\(command.remoteAddress)" }
        return navigationTitle
    }

    /// A new terminal on the same server, or with the same Quick Connect command.
    @MainActor
    func duplicate() {
        if remoteType == .machine {
            AppRouter.shared.openTerminal(machine: machine.id, force: true)
        } else if let command {
            AppRouter.shared.openTerminal(command: command)
        }
    }

    /// "Terminal" and its place among the server's terminals; the shell's
    /// own title (user@host: path) is too long for a row, so it is the
    /// row's tooltip.
    @MainActor
    var sidebarTitle: String {
        let siblings = TerminalManager.shared.sessionContexts.filter { $0.remoteType == .machine && $0.machine.id == machine.id }
        if let index = siblings.firstIndex(where: { $0.id == id }), siblings.count > 1 { return String(localized: "Terminal \(index + 1)") }
        return String(localized: "Terminal")
    }

    /// Reconnects with the details from when this session started.
    func reconnect() {
        guard closed else { return }
        DispatchQueue.global().async {
            self.putInformation(String(localized: "[i] Reconnecting with the details from when this session started."))
            self.putInformation(String(localized: "    If the server was edited, open a new terminal instead."))
            self.processBootstrap()
        }
    }
}
