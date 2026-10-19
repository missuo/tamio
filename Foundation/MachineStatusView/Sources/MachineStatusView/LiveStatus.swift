//
//  LiveStatus.swift
//  MachineStatusView
//
//  Keeps every saved server's status current for the server cards and the
//  Servers table, without opening a monitor: one quiet background session per
//  server that has credentials. An open monitor is used instead of its own.
//

import Combine
import Foundation
import TamioModule

@MainActor
public final class LiveStatusCenter: ObservableObject {
    public static let shared = LiveStatusCenter()

    /// Settings › General: whether servers show live status.
    public static let enabledKey = "sb.moe.tamio.liveStatus"

    @Published public private(set) var sessions: [RDMachine.ID: MonitorSession] = [:]
    @Published public var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            sync()
        }
    }

    /// What each session was started from, to restart it when the server's
    /// address, user or credentials change.
    private var startedFrom: [RDMachine.ID: Fingerprint] = [:]
    /// Temporary leases for servers queried over MCP while the main window is closed.
    private var leasedUntil: [RDMachine.ID: Date] = [:]
    private var leaseTimer: Task<Void, Never>?
    private var windowVisible = true
    private var cancellables = Set<AnyCancellable>()

    private struct Fingerprint: Equatable {
        let address: String
        let port: String
        let username: String
        let identity: String?
        let secret: String
        let withoutCredentials: Bool

        init(_ machine: RDMachine, _ identity: RDIdentity?) {
            address = machine.remoteAddress
            port = machine.remotePort
            username = machine.loginUsername(with: identity)
            self.identity = machine.associatedIdentity
            secret = (identity?.password ?? "") + (identity?.privateKey ?? "")
            withoutCredentials = machine.signsInWithoutCredentials
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Starts following the store; call once at launch.
    public func start() {
        let store = TamioStore.shared
        store.$machineGroup
            .combineLatest(store.$identityGroup)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.sync() }
            .store(in: &cancellables)
        sync()
    }

    /// Pauses background polling while the main window is closed, and resumes
    /// it when the window comes back.
    public func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        sync()
    }

    /// The freshest session for a server: its open monitor, else the
    /// background one.
    public func session(for machine: RDMachine.ID) -> MonitorSession? {
        MonitorCenter.shared.session(for: machine) ?? sessions[machine]
    }

    /// Starts temporary background sessions for `machineIDs` when the main
    /// window is closed so multiple servers connect in parallel. With live
    /// status turned off, an agent's request does not connect either.
    public func lease(_ machineIDs: [RDMachine.ID], ttl: TimeInterval = 60) {
        guard isEnabled, !windowVisible else { return }
        let store = TamioStore.shared
        let expiry = Date().addingTimeInterval(ttl)
        var changed = false
        for id in machineIDs where Self.canFollow(store.machineGroup[id]) {
            leasedUntil[id] = expiry
            changed = true
        }
        guard changed else { return }
        scheduleLeaseSweep(after: ttl)
        sync()
    }

    /// Returns a session with fresh readings, waking a temporary background
    /// session when the main window is closed and MCP asks for metrics.
    public func requestSession(for machineID: RDMachine.ID, ttl: TimeInterval = 60) async -> MonitorSession? {
        if let open = MonitorCenter.shared.session(for: machineID), open.status.hasData {
            return open
        }
        lease([machineID], ttl: ttl)
        guard let session = session(for: machineID) else { return nil }
        if session.status.hasData { return session }
        for _ in 0 ..< 60 {
            if Task.isCancelled { break }
            if session.status.hasData { return session }
            switch session.phase {
            case .failed, .closed: return nil
            case .connecting, .connected: break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return session.status.hasData ? session : nil
    }

    private func scheduleLeaseSweep(after delay: TimeInterval) {
        leaseTimer?.cancel()
        leaseTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, delay + 0.5) * Double(NSEC_PER_SEC)))
            guard let self, !Task.isCancelled else { return }
            self.sync()
        }
    }

    /// Whether a server can be followed: it has a password or key to sign in
    /// with, or signs in with neither.
    public static func canFollow(_ machine: RDMachine) -> Bool {
        machine.isNotPlaceholder() && (machine.signsInWithoutCredentials || TamioStore.shared.associatedIdentity(for: machine) != nil)
    }

    func sync() {
        let now = Date()
        leasedUntil = leasedUntil.filter { $0.value > now }
        let store = TamioStore.shared
        let allFollowable = store.machineGroup.machines.filter(Self.canFollow)
        let wanted: [RDMachine]
        if windowVisible, isEnabled {
            wanted = allFollowable
        } else if isEnabled, !leasedUntil.isEmpty {
            wanted = allFollowable.filter { leasedUntil[$0.id] != nil }
        } else {
            wanted = []
        }
        let wantedIDs = Set(wanted.map(\.id))
        for (id, session) in sessions where !wantedIDs.contains(id) {
            session.shutdown()
            sessions[id] = nil
            startedFrom[id] = nil
        }
        for machine in wanted {
            let identity = store.associatedIdentity(for: machine)
            let fingerprint = Fingerprint(machine, identity)
            if sessions[machine.id] != nil, startedFrom[machine.id] == fingerprint { continue }
            sessions[machine.id]?.shutdown()
            sessions[machine.id] = MonitorSession(machine: machine, identity: identity, recordsConnection: false)
            startedFrom[machine.id] = fingerprint
        }
    }
}
