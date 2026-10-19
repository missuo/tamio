//
//  TransferQueue.swift
//  TamioModule
//
//  Every file transfer of the SFTP page: uploads, downloads, and copies from
//  one server to another (through a temporary folder on this Mac). Each job
//  has a connection of its own, two run at a time, and browsing never waits
//  for them. Folders go whole, with what is in them.
//

import Foundation
import NSRemoteShell

@MainActor
public final class TransferQueue: ObservableObject {
    public static let shared = TransferQueue()

    @Published public private(set) var jobs: [TransferJob] = []
    /// Called on the main thread when a job ends, with the folder it wrote
    /// to, so the panes showing it reload.
    public var onFinish: ((TransferJob) -> Void)?

    public static let concurrent = 2

    public var active: [TransferJob] { jobs.filter { $0.state == .queued || $0.state == .running } }

    /// Overall progress of the jobs not yet done, 0…1.
    public var overallFraction: Double {
        let running = active
        let total = running.map(\.totalBytes).reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(running.map(\.doneBytes).reduce(0, +)) / Double(total)
    }

    public func enqueue(_ job: TransferJob) {
        jobs.append(job)
        pump()
    }

    public func cancel(_ job: TransferJob) {
        job.cancel()
        if job.state == .queued { job.state = .cancelled }
        objectWillChange.send()
        pump()
    }

    public func retry(_ job: TransferJob) {
        guard job.state == .failed || job.state == .cancelled else { return }
        let again = TransferJob(direction: job.direction, sources: job.sources, from: job.from, to: job.to, destination: job.destination)
        jobs.removeAll { $0.id == job.id }
        enqueue(again)
    }

    public func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .cancelled }
    }

    /// Starts what may run. A job's state is its own, so the queue says when
    /// one starts or ends: what shows the queue redraws then, not with every
    /// byte of progress.
    private func pump() {
        let running = jobs.filter { $0.state == .running }.count
        for job in jobs.filter({ $0.state == .queued }).prefix(max(0, Self.concurrent - running)) {
            objectWillChange.send()
            job.state = .running
            Task {
                await job.run()
                objectWillChange.send()
                onFinish?(job)
                pump()
            }
        }
    }
}

@MainActor
public final class TransferJob: ObservableObject, Identifiable {
    public enum Direction: Sendable {
        case upload
        case download
        case relay
    }

    public enum State: Sendable {
        case queued, running, done, failed, cancelled
    }

    public let id = UUID()
    public let direction: Direction
    /// Paths on the side the files come from.
    public let sources: [String]
    /// The server files come from (download, relay), and go to (upload, relay).
    public let from: RDMachine?
    public let to: RDMachine?
    /// The folder they go into.
    public let destination: String

    @Published public internal(set) var state: State = .queued
    @Published public private(set) var currentFile = ""
    @Published public private(set) var doneBytes: Int64 = 0
    @Published public private(set) var totalBytes: Int64 = 0
    @Published public private(set) var bytesPerSecond = 0
    @Published public private(set) var error: String?
    @Published public private(set) var finishedFiles = 0

    private let continueFlag = ContinueFlag()

    public init(direction: Direction, sources: [String], from: RDMachine?, to: RDMachine?, destination: String) {
        self.direction = direction
        self.sources = sources
        self.from = from
        self.to = to
        self.destination = destination
    }

    public var title: String {
        let names = sources.map { ($0 as NSString).lastPathComponent }
        let what = names.count == 1 ? names[0] : String(localized: "\(names.count) items")
        let server = to?.name ?? String(localized: "server")
        switch direction {
        case .upload: return String(localized: "\(what) → \(server)")
        case .download: return String(localized: "\(what) → this Mac")
        case .relay: return String(localized: "\(what) → \(server)")
        }
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : (state == .done ? 1 : 0)
    }

    /// Seconds left at the current speed, nil when unknown.
    public var secondsLeft: Double? {
        guard bytesPerSecond > 0, totalBytes > doneBytes else { return nil }
        return Double(totalBytes - doneBytes) / Double(bytesPerSecond)
    }

    func cancel() {
        continueFlag.stop()
    }

    final class ContinueFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var going = true
        var value: Bool { lock.lock(); defer { lock.unlock() }; return going }
        func stop() { lock.lock(); going = false; lock.unlock() }
    }

    /// What each file's progress reports, folded into the job's totals: the
    /// bytes of finished files plus those of the current one.
    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var finished: Int64 = 0
        private var current: Int64 = 0
        private var lastFile = ""
        func update(file: String, completed: Int64) -> Int64 {
            lock.lock(); defer { lock.unlock() }
            if file != lastFile, !lastFile.isEmpty { finished += current; current = 0 }
            lastFile = file
            current = completed
            return finished + current
        }
    }

    func run() async {
        let job = self
        let sources = sources
        let destination = destination
        let flag = continueFlag
        let direction = direction
        let from = from.map { ($0, TamioStore.shared.associatedIdentity(for: $0)) }
        let to = to.map { ($0, TamioStore.shared.associatedIdentity(for: $0)) }
        let timeout = TamioStore.shared.timeoutNumber
        let report: @Sendable (String, Int64, Int64, Int) -> Void = { file, done, total, speed in
            Task { @MainActor in
                job.currentFile = file
                job.doneBytes = done
                if total > job.totalBytes { job.totalBytes = total }
                job.bytesPerSecond = speed
            }
        }
        let failure: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                func open(_ side: (RDMachine, RDIdentity?)) -> (NSRemoteShell?, String?) {
                    let (machine, identity) = side
                    let shell = NSRemoteShell.configured(for: machine, timeout: timeout)
                    let outcome = shell.connectAndAuthenticate(identity: identity, autoIdentities: TamioStore.shared.workerIdentitiesForAutoAuth, for: machine)
                    guard outcome == .success else {
                        let reason = outcome == .connectFailed ? shell.getLastError() : nil
                        return (nil, shell.hostKeyRefusal ?? reason ?? String(localized: "Could not connect to \(machine.name)."))
                    }
                    shell.requestConnectFileTransferAndWait()
                    guard shell.isConnectedFileTransfer else {
                        return (nil, String(localized: "\(machine.name) does not offer SFTP."))
                    }
                    return (shell, nil)
                }
                func close(_ shell: NSRemoteShell?) {
                    shell?.requestDisconnectAndWait()
                    shell?.destroyPermanently()
                }
                let tally = Tally()
                let progress: NSRemoteFileTransferProgressBlock = { file, progress, speed in
                    let done = tally.update(file: file, completed: progress.completedUnitCount)
                    report((file as NSString).lastPathComponent, done, done - progress.completedUnitCount + progress.totalUnitCount, speed)
                }
                switch direction {
                case .upload:
                    guard let to else { return continuation.resume(returning: String(localized: "No server to upload to.")) }
                    let (shell, error) = open(to)
                    defer { close(shell) }
                    guard let shell else { return continuation.resume(returning: error) }
                    for source in sources where flag.value {
                        if !shell.requestUpload(forFileAndWait: source, toDirectory: destination, onProgress: progress, withContinuationHandler: { flag.value }) {
                            return continuation.resume(returning: flag.value ? (shell.getLastFileTransferError() ?? String(localized: "\((source as NSString).lastPathComponent) could not be uploaded.")) : nil)
                        }
                    }
                    continuation.resume(returning: nil)
                case .download:
                    guard let from else { return continuation.resume(returning: String(localized: "No server to download from.")) }
                    let (shell, error) = open(from)
                    defer { close(shell) }
                    guard let shell else { return continuation.resume(returning: error) }
                    for source in sources where flag.value {
                        let target = (destination as NSString).appendingPathComponent((source as NSString).lastPathComponent)
                        if !shell.requestDownload(fromFileAndWait: source, toLocalPath: target, onProgress: progress, withContinuationHandler: { flag.value }) {
                            return continuation.resume(returning: flag.value ? (shell.getLastFileTransferError() ?? String(localized: "\((source as NSString).lastPathComponent) could not be downloaded.")) : nil)
                        }
                    }
                    continuation.resume(returning: nil)
                case .relay:
                    guard let from, let to else { return continuation.resume(returning: String(localized: "Two servers are needed.")) }
                    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("tamio-relay-\(UUID().uuidString)")
                    try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let (source, sourceError) = open(from)
                    defer { close(source) }
                    guard let source else { return continuation.resume(returning: sourceError) }
                    let (target, targetError) = open(to)
                    defer { close(target) }
                    guard let target else { return continuation.resume(returning: targetError) }
                    for path in sources where flag.value {
                        let local = staging.appendingPathComponent((path as NSString).lastPathComponent).path
                        guard source.requestDownload(fromFileAndWait: path, toLocalPath: local, onProgress: progress, withContinuationHandler: { flag.value }) else {
                            return continuation.resume(returning: flag.value ? (source.getLastFileTransferError() ?? String(localized: "\((path as NSString).lastPathComponent) could not be read.")) : nil)
                        }
                        guard target.requestUpload(forFileAndWait: local, toDirectory: destination, onProgress: progress, withContinuationHandler: { flag.value }) else {
                            return continuation.resume(returning: flag.value ? (target.getLastFileTransferError() ?? String(localized: "\((path as NSString).lastPathComponent) could not be written.")) : nil)
                        }
                    }
                    continuation.resume(returning: nil)
                }
            }
        }
        bytesPerSecond = 0
        finishedFiles = sources.count
        if !continueFlag.value {
            state = .cancelled
        } else if let failure {
            error = failure
            state = .failed
        } else {
            if totalBytes == 0 { totalBytes = max(doneBytes, 1); doneBytes = totalBytes }
            doneBytes = totalBytes
            state = .done
        }
    }
}

/// One file or folder from a server, fetched on its own connection: what a
/// drag out to Finder asks for once it is dropped.
public enum RemoteFetch {
    /// Downloads `path` from `machine` into `folder`, on a background queue,
    /// and calls back with the local copy, or nil.
    public static func download(
        _ path: String, from machine: RDMachine, into folder: URL,
        completion: @escaping @Sendable (URL?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let identity = TamioStore.shared.associatedIdentity(for: machine)
        let timeout = TamioStore.shared.timeoutNumber
        let autoIdentities = TamioStore.shared.workerIdentitiesForAutoAuth
        nonisolated(unsafe) let report = progress
        DispatchQueue.global(qos: .userInitiated).async {
            let shell = NSRemoteShell.configured(for: machine, timeout: timeout)
            defer {
                shell.requestDisconnectAndWait()
                shell.destroyPermanently()
            }
            guard shell.connectAndAuthenticate(identity: identity, autoIdentities: autoIdentities, for: machine) == .success else {
                return completion(nil)
            }
            shell.requestConnectFileTransferAndWait()
            guard shell.isConnectedFileTransfer else { return completion(nil) }
            let target = folder.appendingPathComponent((path as NSString).lastPathComponent)
            let done = shell.requestDownload(fromFileAndWait: path, toLocalPath: target.path, onProgress: { _, step, _ in
                if step.totalUnitCount > 0 { report.completedUnitCount = Int64(Double(step.completedUnitCount) / Double(step.totalUnitCount) * 100) }
            }, withContinuationHandler: { !report.isCancelled })
            completion(done ? target : nil)
        }
        return progress
    }
}
