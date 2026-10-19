//
//  AppRouter.swift
//  Tamio (macOS)
//
//  The main window's navigation state and the actions that open sessions.
//

import Combine
import MachineStatusView
import TamioModule
import TamioTerminal
import SwiftUI

enum Route: Hashable {
    case home
    case servers
    case identities
    case snippets
    case portForward
    case settings
    case terminal(UUID)
    case monitor(UUID)
    case transfer(UUID)
}

/// The router and everything it publishes are main-thread state, like the
/// interface it drives.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var route: Route = .home {
        didSet {
            if !route.isSession {
                lastPlace = route
            } else if let owner = owner(of: route) {
                lastRoute[owner] = route
                if case let .terminal(id) = route { lastTerminal[owner] = id }
            }
        }
    }
    /// The page each server (or Quick Connect terminal) showed last, so its
    /// sidebar row returns to the same tool.
    private var lastRoute: [SessionOwner: Route] = [:]
    /// The terminal each server showed last, for the switcher's Terminal.
    private var lastTerminal: [SessionOwner: UUID] = [:]

    /// The server's terminal used last, else its first.
    func preferredTerminal(of owner: SessionOwner) -> TerminalManager.Context? {
        let open = terminals(of: owner)
        return open.first { $0.id == lastTerminal[owner] } ?? open.first
    }
    /// The last page that is not a session; closing a session returns here.
    private(set) var lastPlace: Route = .home
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// The server editor panel at the trailing edge of the window: a new
    /// server, or one being edited. Nil when the panel is closed.
    @Published var serverEditor: ServerEditorTarget?
    /// Opens the panel for a new server from anywhere (menu, Home, Servers).
    var presentNewServer: Bool {
        get { serverEditor == .new }
        set { serverEditor = newValue ? .new : nil }
    }
    /// Settings category to show when Settings opens.
    /// Settings follows this itself, so a change of category does not go
    /// through every view that watches the router.
    let settingsNavigation = ConfigNavigation(SettingsCategory.general)
    var settingsSelection: String {
        get { settingsNavigation.selection }
        set { settingsNavigation.go(newValue) }
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // When a session closes, leave its page.
        leaveWhenSessionEnds(TerminalManager.shared.$sessionContexts) {
            if case let .terminal(id) = $0 { return id }
            return nil
        }
        leaveWhenSessionEnds(MonitorCenter.shared.$sessions) {
            if case let .monitor(id) = $0 { return id }
            return nil
        }
        leaveWhenSessionEnds(FileTransferManager.shared.$transfers) {
            if case let .transfer(id) = $0 { return id }
            return nil
        }
    }

    /// Returns to the last non-session place once the open session page's id
    /// leaves the published list, meaning its session has closed.
    private func leaveWhenSessionEnds<Element: Identifiable>(
        _ publisher: Published<[Element]>.Publisher,
        id routeID: @escaping (Route) -> UUID?
    ) where Element.ID == UUID {
        publisher
            .sink { [weak self] sessions in
                guard let self, let id = routeID(self.route) else { return }
                if !sessions.contains(where: { $0.id == id }) { self.route = self.lastPlace }
            }
            .store(in: &cancellables)
    }

    private var opensAutomatically: Bool {
        TamioStore.shared.openInterfaceAutomatically
    }

    // MARK: - Session actions

    /// A terminal on the server; `force` opens another without asking when
    /// one is open (Duplicate Terminal).
    func openTerminal(machine: RDMachine.ID, force: Bool = false) {
        let machineObject = TamioStore.shared.machineGroup[machine]
        guard machineObject.isNotPlaceholder() else {
            Dialogs.presentError(with: String(localized: "This server's details could not be read."))
            return
        }
        TerminalManager.shared.createSession(withMachineObject: machineObject, force: force) { [weak self] context in
            guard let self, force || self.opensAutomatically else { return }
            self.route = .terminal(context.id)
        }
    }

    /// A new terminal on the server that runs `initialCommand` once signed in.
    func openTerminal(machine: RDMachine.ID, initialCommand: String) {
        let manager = TerminalManager.shared
        let machineObject = TamioStore.shared.machineGroup[machine]
        guard machineObject.isNotPlaceholder() else { return }
        manager.createSession(withMachineObject: machineObject, force: true) { [weak self] context in
            context.initialCommand = initialCommand
            self?.route = .terminal(context.id)
        }
    }

    func openTerminal(command: SSHCommandReader) {
        let context = TerminalManager.shared.createSession(withCommand: command)
        if opensAutomatically { route = .terminal(context.id) }
    }

    func openMonitor(machine: RDMachine.ID) {
        do {
            let session = try MonitorCenter.shared.begin(for: machine)
            route = .monitor(session.id)
        } catch {
            Dialogs.presentError(with: error.localizedDescription)
        }
    }

    func openFileTransfer(machine: RDMachine.ID) {
        let manager = FileTransferManager.shared
        if let existing = manager.transfers.first(where: { $0.machine.id == machine }) {
            route = .transfer(existing.id)
            return
        }
        manager.begin(for: machine)
        // Like Monitor, Files opens its page right away and connects in place.
        if let started = manager.transfers.last(where: { $0.machine.id == machine }) {
            route = .transfer(started.id)
        }
    }

    @MainActor
    func showInMenuBar(machine: RDMachine.ID) {
        MenubarTool.shared.createRuncat(for: machine)
    }

    /// Pick one or more servers, then open a terminal for each.
    @MainActor
    func openTerminals() {
        ServerPickerPanel.present(
            title: "Open Terminals",
            confirmTitle: "Open",
            allowsMany: true
        ) { machines in
            for machine in machines {
                TerminalManager.shared.createSession(withMachineID: machine) { _ in }
            }
            if let first = TerminalManager.shared.sessionContexts.last(where: { machines.contains($0.machine.id) }),
               self.opensAutomatically
            {
                self.route = .terminal(first.id)
            }
        }
    }

    // MARK: - Sessions by server

    /// Who a session page belongs to.
    func owner(of route: Route) -> SessionOwner? {
        switch route {
        case let .terminal(id):
            guard let context = TerminalManager.shared.sessionContexts.first(where: { $0.id == id }) else { return nil }
            return context.remoteType == .machine ? .server(context.machine.id) : .command(context.id)
        case let .transfer(id):
            return FileTransferManager.shared.transfers.first { $0.id == id }.map { .server($0.machine.id) }
        case let .monitor(id):
            return MonitorCenter.shared.session(withID: id).map { .server($0.machine.id) }
        default:
            return nil
        }
    }

    /// Every open session page, terminals first, then files and monitors.
    var sessionRoutes: [Route] {
        TerminalManager.shared.sessionContexts.map { .terminal($0.id) }
            + FileTransferManager.shared.transfers.map { .transfer($0.id) }
            + MonitorCenter.shared.sessions.map { .monitor($0.id) }
    }

    /// Servers and Quick Connect terminals with something open, in the order
    /// their first session opened.
    var openOwners: [SessionOwner] {
        var seen = Set<SessionOwner>()
        return sessionRoutes.compactMap(owner(of:)).filter { seen.insert($0).inserted }
    }

    /// The terminals of a server or Quick Connect command, in the order they opened.
    func terminals(of owner: SessionOwner) -> [TerminalManager.Context] {
        TerminalManager.shared.sessionContexts.filter { context in
            switch owner {
            case let .server(id): return context.remoteType == .machine && context.machine.id == id
            case let .command(id): return context.id == id
            }
        }
    }

    func routes(of owner: SessionOwner) -> [Route] {
        sessionRoutes.filter { self.owner(of: $0) == owner }
    }

    /// Shows a server's sessions: the tool it showed last, else the first open one.
    func show(_ owner: SessionOwner) {
        let open = routes(of: owner)
        if let last = lastRoute[owner], open.contains(last) {
            route = last
        } else if let first = open.first {
            route = first
        }
    }

    /// Closes every session of a server or Quick Connect terminal.
    @MainActor
    func closeAll(_ owner: SessionOwner) {
        for route in routes(of: owner) {
            switch route {
            case let .terminal(id):
                if let context = TerminalManager.shared.sessionContexts.first(where: { $0.id == id }) {
                    TerminalManager.shared.closeSession(withContextID: context.id)
                }
            case let .transfer(id):
                FileTransferManager.shared.end(for: id)
            case let .monitor(id):
                MonitorCenter.shared.end(id)
            default:
                break
            }
        }
    }

    func openSettings(_ category: String = SettingsCategory.general) {
        settingsSelection = category
        route = .settings
    }
}

enum ServerEditorTarget: Hashable {
    case new
    case edit(RDMachine.ID)

    var machine: RDMachine.ID? {
        if case let .edit(id) = self { return id }
        return nil
    }
}

/// What owns a group of session pages: a saved server, or one Quick Connect
/// terminal (which has no saved server to group under).
enum SessionOwner: Hashable {
    case server(RDMachine.ID)
    case command(UUID)
}

extension Route {
    var isSession: Bool {
        switch self {
        case .terminal, .monitor, .transfer: return true
        default: return false
        }
    }
}

enum SettingsCategory {
    static let general = "general"
    static let about = "about"
}
