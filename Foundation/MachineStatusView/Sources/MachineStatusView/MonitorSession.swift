//
//  MonitorSession.swift
//  MachineStatusView
//
//  A live monitor of one server: connects over SSH, samples native system metrics
//  on every refresh and keeps the history for the sparklines.
//

import Combine
import Foundation
import MachineStatus
import NSRemoteShell
import TamioModule

/// Samples collected by the app while a monitor is open (one per refresh).
public struct MonitorHistory: Equatable {
    public static let capacity = 60

    public private(set) var cpu: [Double] = []
    public private(set) var memory: [Double] = []
    public private(set) var receive: [Double] = []
    public private(set) var transmit: [Double] = []

    public init() {}

    mutating func record(_ status: ServerStatus) {
        Self.push(Double(status.processor.summary.sumUsed), to: &cpu)
        Self.push(status.memoryUsedPercent, to: &memory)
        Self.push(Double(status.totalReceivePerSecond), to: &receive)
        Self.push(Double(status.totalTransmitPerSecond), to: &transmit)
    }

    private static func push(_ value: Double, to list: inout [Double]) {
        list.append(value.isFinite ? value : 0)
        if list.count > capacity { list.removeFirst(list.count - capacity) }
    }
}

public extension ServerStatus {
    var totalReceivePerSecond: Int {
        network.elements.map(\.rxBytesPerSec).reduce(0, &+)
    }

    var totalTransmitPerSecond: Int {
        network.elements.map(\.txBytesPerSec).reduce(0, &+)
    }

    /// Memory readings are stored in kB on every platform.
    var memoryUsedKB: Double {
        Double(max(0, memory.memTotal - memory.memFree - memory.memCached - memory.memBuffers))
    }

    var memoryCacheKB: Double {
        Double(max(0, memory.memCached + memory.memBuffers))
    }

    var memoryUsedPercent: Double {
        guard memory.memTotal > 0 else { return 0 }
        return memoryUsedKB / Double(memory.memTotal) * 100
    }

    /// CPUs: the reported count, else the per-core rows, else one.
    var cores: Int {
        if cpuCount > 0 { return cpuCount }
        return max(1, processor.cores.count)
    }

    var hasData: Bool {
        !system.hostname.isEmpty || memory.memTotal > 0
    }
}

public final class MonitorSession: ObservableObject, Identifiable, Equatable {
    public enum Phase: Equatable {
        case connecting
        case connected
        case failed(String)
        case closed
    }

    public let id = UUID()
    public let machine: RDMachine
    let identity: RDIdentity?
    /// Whether each refresh is recorded on the server as its last
    /// connection. Background status (server cards) is not: it would save
    /// and sync the store every few seconds.
    let recordsConnection: Bool

    public let status = ServerStatus()
    @Published public private(set) var phase: Phase = .connecting {
        didSet {
            #if DEBUG
                if phase != oldValue { Self.trace("\(machine.name) phase \(phase)") }
            #endif
        }
    }
    @Published public private(set) var history = MonitorHistory()
    @Published public private(set) var lastUpdate: Date?
    @Published public private(set) var isRefreshing = false

    private var shell: NSRemoteShell
    private var updateTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private static let queue = DispatchQueue(label: "sb.moe.tamio.monitor", attributes: .concurrent)

    public init(machine: RDMachine, identity: RDIdentity?, recordsConnection: Bool = true) {
        self.machine = machine
        self.identity = identity
        self.recordsConnection = recordsConnection
        shell = NSRemoteShell.configured(for: machine, timeout: TamioStore.shared.timeoutNumber)
        // Re-publish nested status changes so one observer is enough.
        status.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        updateTask = Task.detached { [weak self] in
            await self?.updateLoop()
        }
    }

    #if DEBUG
        /// A session filled with sample readings that never connects, for checking
        /// layouts (menu bar popover, monitor page) without a server.
        public static func preview(machine: RDMachine) -> MonitorSession {
            MonitorSession(previewing: machine)
        }

        private init(previewing machine: RDMachine) {
            self.machine = machine
            identity = nil
            recordsConnection = false
            shell = NSRemoteShell()
            status.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
            let core = ServerStatus.ProcessPercentInfo(system: 6.2, user: 18.4, iowait: 1.1, nice: 0.3, sum: 26)
            var cores: [String: ServerStatus.ProcessPercentInfo] = [:]
            for index in 0 ..< 8 {
                let used = Float(13 + index * 6)
                cores["cpu\(index)"] = ServerStatus.ProcessPercentInfo(system: 4, user: used - 5, iowait: 1, nice: 0, sum: used)
            }
            status.processor = ServerStatus.ProcessorInfo(summary: core, cores: cores)
            status.memory = .init(total: 16_384_000, free: 3_100_000, buffers: 420_000, cached: 5_200_000, swapTotal: 4_096_000, swapFree: 3_500_000)
            status.system = .init(release: "Ubuntu 24.04.1 LTS", uptimeInSec: 1_728_000, hostname: "web-01",
                                  runningProcs: 3, totalProcs: 412, load1: 0.82, load5: 0.64, load15: 0.51)
            status.network = .init(elements: [
                .init(device: "eth0", rxBytesPerSec: 2_400_000, txBytesPerSec: 640_000),
                .init(device: "docker0", rxBytesPerSec: 81_000, txBytesPerSec: 96_000),
            ])
            status.fileSystem = .init(elements: [
                .init(mountPoint: "/", size: "98G", used: "41G", free: "52G", percent: 44),
                .init(mountPoint: "/data", size: "1.8T", used: "1.3T", free: "450G", percent: 74),
            ])
            phase = .connected
            for step in 0 ..< 40 {
                status.network = .init(elements: [
                    .init(device: "eth0", rxBytesPerSec: 1_600_000 + (step % 7) * 260_000, txBytesPerSec: 400_000 + (step % 5) * 90_000),
                    .init(device: "docker0", rxBytesPerSec: 81_000, txBytesPerSec: 96_000),
                ])
                history.record(status)
            }
            lastUpdate = Date()
        }
    #endif

    public static func == (lhs: MonitorSession, rhs: MonitorSession) -> Bool {
        lhs.id == rhs.id
    }

    public var refreshInterval: Int {
        // Read from the update loop's task; the store's worker snapshot.
        max(1, TamioStore.shared.workerMonitorInterval)
    }

    private func updateLoop() async {
        var failures = 0
        /// Rounds in a row that read nothing; a server that never answers
        /// is not reconnected every second.
        var emptyRounds = 0
        while !Task.isCancelled {
            if !(shell.isConnected && shell.isAuthenticated) {
                // Statics belong to the connection; a reconnect may land on
                // a reimaged or different host.
                status.resetSessionStatics()
                onMainThread { if self.phase != .connected { self.phase = .connecting } }
                await blocking { self.connectAndAuthenticate() }
            }
            if Task.isCancelled { break }
            if shell.isConnected, shell.isAuthenticated {
                failures = 0
                onMainThread {
                    self.phase = .connected
                    self.isRefreshing = true
                    guard self.recordsConnection else { return }
                    var read = TamioStore.shared.machineGroup[self.machine.id]
                    if read.isNotPlaceholder() {
                        read.lastBanner = self.shell.remoteBanner ?? read.lastBanner
                        read.lastConnection = Date()
                        TamioStore.shared.machineGroup[self.machine.id] = read
                    }
                }
                let timeout = max(10, Double(refreshInterval * 2))
                let round = RoundResult()
                await blocking { round.read = self.status.requestInfoAndWait(with: self.shell, timeout: timeout) }
                #if DEBUG
                    Self.trace("\(machine.name) round \(round.read ? "read" : "empty") hasData \(status.hasData)")
                #endif
                if !round.read {
                    // Nothing came back: the connection is gone (the Mac slept,
                    // the network changed). The last readings stay on screen;
                    // the connection is dropped and made again in a second.
                    onMainThread { self.isRefreshing = false }
                    await blocking { self.shell.requestDisconnectAndWait() }
                    emptyRounds += 1
                    let pause = emptyRounds == 1 ? 1 : min(30, 5 * (emptyRounds - 1))
                    try? await Task.sleep(nanoseconds: UInt64(pause) * NSEC_PER_SEC)
                    continue
                }
                emptyRounds = 0
                // The status updates were queued on main; record after them.
                onMainThread {
                    self.history.record(self.status)
                    self.lastUpdate = Date()
                    self.isRefreshing = false
                }
            } else {
                failures += 1
                let message = shell.hostKeyRefusal ?? shell.getLastError() ?? String(localized: "Unable to connect or authenticate")
                onMainThread { self.phase = .failed(message) }
            }
            let wait = failures > 0 ? min(30, 5 * failures) : refreshInterval
            // Parks the task instead of squatting on a thread in sleep(1);
            // cancellation from shutdown() lands here right away.
            try? await Task.sleep(nanoseconds: UInt64(wait) * NSEC_PER_SEC)
        }
        onMainThread { self.phase = .closed }
    }

    #if DEBUG
        /// Debug builds started with TAMIO_TRACE=<file> append the loop's
        /// steps to that file.
        static func trace(_ message: String) {
            guard let path = ProcessInfo.processInfo.environment["TAMIO_TRACE"], let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(Data("\(Date().timeIntervalSince1970) \(message)\n".utf8))
            handle.closeFile()
        }
    #endif

    /// Whether a refresh round read anything, set on the monitor queue.
    private final class RoundResult: @unchecked Sendable {
        var read = false
    }

    /// The SSH API blocks; run it on the monitor queue so the loop's task
    /// suspends at the await instead of blocking a cooperative-pool thread
    /// for the whole round.
    private func blocking(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            MonitorSession.queue.async {
                work()
                continuation.resume()
            }
        }
    }

    /// Runs a command over the session's connection (a process list, the
    /// containers), nil while it is not connected.
    public func run(_ command: String, timeout: Double = 15) async -> String? {
        guard phase == .connected else { return nil }
        let shell = shell
        nonisolated(unsafe) var output: String?
        await blocking {
            guard shell.isConnected, shell.isAuthenticated else { return }
            output = ServerStatus.downloadResultFrom(shell: shell, command: command, timeout: timeout)
        }
        return output
    }

    private func connectAndAuthenticate() {
        shell.connectAndAuthenticate(
            identity: identity,
            autoIdentities: TamioStore.shared.workerIdentitiesForAutoAuth,
            for: machine
        )
    }

    public func shutdown() {
        updateTask?.cancel()
        let shell = shell
        MonitorSession.queue.async {
            shell.requestDisconnectAndWait()
            shell.destroyPermanently()
        }
    }
}

/// Owns the open monitors of the app. Main thread, like the views and
/// menu bar items that show the sessions.
@MainActor
public final class MonitorCenter: ObservableObject {
    public static let shared = MonitorCenter()

    @Published public private(set) var sessions: [MonitorSession] = []

    private init() {}

    public enum BeginError: LocalizedError {
        case malformedMachine

        public var errorDescription: String? {
            switch self {
            case .malformedMachine: return String(localized: "This server's details could not be read.")
            }
        }
    }

    public func session(for machine: RDMachine.ID) -> MonitorSession? {
        sessions.first { $0.machine.id == machine }
    }

    public func session(withID id: MonitorSession.ID) -> MonitorSession? {
        sessions.first { $0.id == id }
    }

    /// Returns the running monitor for the server, or starts one.
    @discardableResult
    public func begin(for machineID: RDMachine.ID) throws -> MonitorSession {
        if let existing = session(for: machineID) { return existing }
        let machine = TamioStore.shared.machineGroup[machineID]
        guard machine.isNotPlaceholder() else { throw BeginError.malformedMachine }
        let session = MonitorSession(machine: machine, identity: TamioStore.shared.associatedIdentity(for: machine))
        sessions.append(session)
        TamioStore.shared.storeRecentIfNeeded(from: machineID)
        return session
    }

    public func end(_ id: MonitorSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        session.shutdown()
    }

    public func closeAll() {
        guard !sessions.isEmpty else { return }
        let open = sessions
        sessions = []
        for session in open { session.shutdown() }
    }

}

/// Published state changes on the main thread only and the shell is used on
/// the session's own queue, so a session may be handed between them.
extension MonitorSession: @unchecked Sendable {}
