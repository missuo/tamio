//
//  BatchSnippetExecContext.swift
//  Tamio
//
//  The per-server run lives in TamioModule.SnippetExecSession; this
//  context keeps the batch: per-machine buffers, state and stop.
//

import Combine
import NSRemoteShell
import TamioModule

/// Every field is read and written under `accessLock`, from the run's queues
/// and the sheet's.
final class BatchSnippetExecContext: ObservableObject, @unchecked Sendable {
    let snippet: RDSnippet
    let machines: [RDMachine.ID]
    let names: [RDMachine.ID: String]
    init(snippet: RDSnippet, machines: [RDMachine.ID]) {
        self.snippet = snippet
        self.machines = machines
        var buildNames: [RDMachine.ID: String] = [:]
        for machine in machines {
            // run this in main thread
            let object = TamioStore.shared.machineGroup[machine]
            guard object.isNotPlaceholder() else {
                debugPrint("garbage machine found")
                receivedBuffer[machine] = "\r\n[*] \(String(localized: "Malformed Machine Info"))\r\n"
                continue
            }
            shellObjects[object.id] = NSRemoteShell
                .configured(for: object, timeout: TamioStore.shared.timeoutNumber)
            shellContinue[object.id] = true
            buildNames[machine] = object.name
        }
        names = buildNames
    }

    deinit {
        debugPrint("\(self) \(#function)")
    }

    private var didStart = false

    /// Starts the run on every server. The sheet calls this from onAppear, so
    /// creating the context alone never touches a server.
    func start() {
        accessLock.lock()
        let shouldStart = !didStart
        didStart = true
        accessLock.unlock()
        guard shouldStart else { return }
        DispatchQueue.global().async {
            self.beingExecution()
        }
    }

    var shellObjects: [RDMachine.ID: NSRemoteShell] = [:]

    private var shellContinue: [RDMachine.ID: Bool] = [:]
    private var receivedBuffer: [RDMachine.ID: String] = [:]
    private var completedMachines: [RDMachine.ID] = []
    private var consumedBufferCount: [UUID: Int] = [:]
    private var droppedBufferCount: [RDMachine.ID: Int] = [:]
    private var startedAt: [RDMachine.ID: Date] = [:]
    private var finishedAt: [RDMachine.ID: Date] = [:]
    private var failedMachines: Set<RDMachine.ID> = []

    enum MachineState {
        case waiting
        case running(since: Date)
        case done(duration: TimeInterval)
        case failed(duration: TimeInterval)
    }

    func state(for machine: RDMachine.ID) -> MachineState {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let start = startedAt[machine] else { return .waiting }
        if let end = finishedAt[machine] {
            let duration = end.timeIntervalSince(start)
            return failedMachines.contains(machine) ? .failed(duration: duration) : .done(duration: duration)
        }
        return .running(since: start)
    }

    /// Asks every running command to stop.
    func stopAll() {
        safeAccess {
            for key in shellContinue.keys {
                shellContinue[key] = false
            }
        }
        DispatchQueue.global().async {
            self.safeAccessShellObjects.values.forEach { $0.requestDisconnectAndWait() }
        }
    }

    var safeAccessShellObjects: [RDMachine.ID: NSRemoteShell] {
        accessLock.lock()
        let value = shellObjects
        accessLock.unlock()
        return value
    }

    var safeAccessShellContinue: [RDMachine.ID: Bool] {
        accessLock.lock()
        let value = shellContinue
        accessLock.unlock()
        return value
    }

    var safeAccessCompletedMachines: [RDMachine.ID] {
        accessLock.lock()
        let value = completedMachines
        accessLock.unlock()
        return value
    }

    let accessLock = NSLock()
    func safeAccess(on: () -> Void) {
        accessLock.lock()
        on()
        accessLock.unlock()
    }

    func beingExecution() {
        let queue = DispatchQueue(
            label: "sb.moe.tamio.exec.batch.\(snippet.name)",
            attributes: .concurrent
        )
        let machines = machines
        queue.async {
            let group = DispatchGroup()
            for machine in machines {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    self.beginExec(on: machine)
                }
            }
            group.wait()
        }
    }

    /// A terminal reads by absolute position, so truncating the buffer's front
    /// never replays output: one behind the truncation point gets what is left.
    func requestBuffer(for terminalId: UUID, machine: UUID) -> String {
        accessLock.lock()
        let buffer = receivedBuffer[machine, default: ""]
        let dropped = droppedBufferCount[machine, default: 0]
        let consumed = consumedBufferCount[terminalId, default: 0]
        let write = consumed <= dropped ? buffer : String(buffer.dropFirst(consumed - dropped))
        consumedBufferCount[terminalId] = dropped + buffer.count
        accessLock.unlock()
        return write
    }

    private static let bufferLimit = 1024 * 1024

    /// Keeps a flooding command from growing a machine's buffer without bound.
    /// Call with accessLock held.
    private func lockedAppendToBuffer(_ output: String, for machine: RDMachine.ID) {
        receivedBuffer[machine, default: ""].append(output)
        let count = receivedBuffer[machine, default: ""].count
        guard count > Self.bufferLimit else { return }
        let excess = count - Self.bufferLimit
        receivedBuffer[machine, default: ""].removeFirst(excess)
        droppedBufferCount[machine, default: 0] += excess
    }

    private func appendToBuffer(_ output: String, for machine: RDMachine.ID) {
        safeAccess {
            self.lockedAppendToBuffer(output, for: machine)
        }
    }

    func beginExec(on machine: RDMachine.ID) {
        safeAccess { self.startedAt[machine] = Date() }
        // Done the moment the command has returned: the hang-up that follows
        // can take seconds, and is no part of the user's wait.
        defer {
            debugPrint("execution subroutine completed for machine: \(machine)")
            safeAccess {
                self.completedMachines.append(machine)
                self.finishedAt[machine] = Date()
            }
            // The sheet draws the server as done at once, not on its next tick.
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
        guard let shell = safeAccessShellObjects[machine] else {
            // our error not user's
            debugPrint("missing shell for machine: \(machine)")
            safeAccess { self.failedMachines.insert(machine) }
            return
        }
        defer { DispatchQueue.global().async { shell.requestDisconnectAndWait() } }
        let remote = TamioStore.shared.workerMachine(for: machine)
        guard remote.isNotPlaceholder() else {
            // the server was removed after the run started
            debugPrint("machine vanished mid-run: \(machine)")
            safeAccess { self.failedMachines.insert(machine) }
            return
        }
        let outcome = SnippetExecSession(machine: remote, shell: shell).execute(
            snippet.code,
            onBegin: {
                debugPrint("channel begin")
                self.appendToBuffer("[*] \(String(localized: "Execute Begin"))\r\n", for: machine)
            },
            onOutput: { output in
                self.appendToBuffer(output, for: machine)
            },
            withContinuationHandler: {
                // safeAccess executes synchronously under the lock; wrapping it in
                // a semaphore only adds deadlock surface without any benefit.
                self.safeAccessShellContinue[machine] ?? false
            }
        )
        switch outcome {
        case .completed:
            safeAccess {
                self.shellObjects.removeValue(forKey: machine)
                self.lockedAppendToBuffer("\r\n[*] \(String(localized: "Execution completed"))\r\n", for: machine)
            }
        case .connectFailed:
            debugPrint("failed to connect to remote machine: \(machine)")
            let reason = shell.getLastError()
            safeAccess {
                self.lockedAppendToBuffer("\r\n[E] \(reason ?? String(localized: "Could not connect to the server"))\r\n", for: machine)
                self.failedMachines.insert(machine)
            }
        case .authenticateFailed:
            debugPrint("auth failed for machine: \(machine)")
            safeAccess {
                self.lockedAppendToBuffer("\r\n[E] \(String(localized: "The identity could not sign in"))\r\n", for: machine)
                self.failedMachines.insert(machine)
            }
        }
    }
}
