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
        let again = TransferJob(direction: job.direction, sources: job.sources, from: job.from, to: job.to, destination: job.destination, collision: job.collision)
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

    /// What the job does with an item of the same name already in the
    /// destination. The user picks it before the job is queued; the job
    /// applies it to what is there when it runs.
    public enum Collision: Sendable {
        /// The copy takes its place: a file overwrites the one there, and a
        /// folder is merged into the folder there. When one is a file and the
        /// other a folder, the one there is removed first (to the Trash, on
        /// this Mac).
        case replace
        /// The copy gets a name not yet taken, as in Finder: "notes 2.txt".
        case keepBoth
        /// The item is left out.
        case skip
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
    public let collision: Collision

    @Published public internal(set) var state: State = .queued
    @Published public private(set) var currentFile = ""
    @Published public private(set) var doneBytes: Int64 = 0
    @Published public private(set) var totalBytes: Int64 = 0
    @Published public private(set) var bytesPerSecond = 0
    @Published public private(set) var error: String?
    @Published public private(set) var finishedFiles = 0

    private let continueFlag = ContinueFlag()

    public init(direction: Direction, sources: [String], from: RDMachine?, to: RDMachine?, destination: String, collision: Collision = .replace) {
        self.direction = direction
        self.sources = sources
        self.from = from
        self.to = to
        self.destination = destination
        self.collision = collision
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
        let collision = collision
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
                    var existing = TransferPlacement.remoteNames(in: destination, on: shell)
                    for source in sources where flag.value {
                        var isDirectory: ObjCBool = false
                        FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory)
                        guard let place = TransferPlacement.place((source as NSString).lastPathComponent, isDirectory: isDirectory.boolValue, among: &existing, collision) else { continue }
                        let target = (destination as NSString).appendingPathComponent(place.name)
                        if place.clearing, !TransferPlacement.removeRemote(target, on: shell) {
                            return continuation.resume(returning: String(localized: "\(place.name) could not be replaced."))
                        }
                        if !shell.requestUpload(forFileAndWait: source, toDirectory: destination, named: place.name, onProgress: progress, withContinuationHandler: { flag.value }) {
                            return continuation.resume(returning: flag.value ? (shell.getLastFileTransferError() ?? String(localized: "\((source as NSString).lastPathComponent) could not be uploaded.")) : nil)
                        }
                    }
                    continuation.resume(returning: nil)
                case .download:
                    guard let from else { return continuation.resume(returning: String(localized: "No server to download from.")) }
                    let (shell, error) = open(from)
                    defer { close(shell) }
                    guard let shell else { return continuation.resume(returning: error) }
                    var existing = TransferPlacement.localNames(in: destination)
                    for source in sources where flag.value {
                        let isDirectory = shell.requestFileInfo(at: source)?.isDirectory ?? false
                        guard let place = TransferPlacement.place((source as NSString).lastPathComponent, isDirectory: isDirectory, among: &existing, collision) else { continue }
                        let target = (destination as NSString).appendingPathComponent(place.name)
                        if place.clearing, !TransferPlacement.removeLocal(target) {
                            return continuation.resume(returning: String(localized: "\(place.name) could not be replaced."))
                        }
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
                    var existing = TransferPlacement.remoteNames(in: destination, on: target)
                    for path in sources where flag.value {
                        let isDirectory = source.requestFileInfo(at: path)?.isDirectory ?? false
                        guard let place = TransferPlacement.place((path as NSString).lastPathComponent, isDirectory: isDirectory, among: &existing, collision) else { continue }
                        // Staged under the name it takes on the target, which
                        // the upload keeps.
                        let local = staging.appendingPathComponent(place.name).path
                        defer { try? FileManager.default.removeItem(atPath: local) }
                        guard source.requestDownload(fromFileAndWait: path, toLocalPath: local, onProgress: progress, withContinuationHandler: { flag.value }) else {
                            return continuation.resume(returning: flag.value ? (source.getLastFileTransferError() ?? String(localized: "\((path as NSString).lastPathComponent) could not be read.")) : nil)
                        }
                        // Only once the copy is in hand, so a failed read
                        // leaves what is there alone.
                        if place.clearing, !TransferPlacement.removeRemote((destination as NSString).appendingPathComponent(place.name), on: target) {
                            return continuation.resume(returning: String(localized: "\(place.name) could not be replaced."))
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

/// Where each item of a transfer goes in its destination folder, given what
/// is already there and the job's `Collision`.
public enum TransferPlacement {
    /// The name `name` takes among `existing` (names in the destination, true
    /// for folders), nil to leave it out; `clearing` when what is there must
    /// be removed first. The name is added to `existing`, so a later item of
    /// the same job sees it.
    static func place(
        _ name: String, isDirectory: Bool, among existing: inout [String: Bool], _ collision: TransferJob.Collision
    ) -> (name: String, clearing: Bool)? {
        guard let there = existing[name] else {
            existing[name] = isDirectory
            return (name, false)
        }
        switch collision {
        case .skip:
            return nil
        case .replace:
            existing[name] = isDirectory
            return (name, there != isDirectory)
        case .keepBoth:
            let free = freeName(for: name, isDirectory: isDirectory, taken: Set(existing.keys))
            existing[free] = isDirectory
            return (free, false)
        }
    }

    /// "notes.txt" becomes "notes 2.txt", then "notes 3.txt", as Finder names
    /// a copy kept beside the original; a folder keeps its dots whole.
    public static func freeName(for name: String, isDirectory: Bool, taken: Set<String>) -> String {
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            if !taken.contains(candidate) { return candidate }
            number += 1
        }
    }

    static func remoteNames(in folder: String, on shell: NSRemoteShell) -> [String: Bool] {
        var names: [String: Bool] = [:]
        for file in shell.requestFileList(at: folder) ?? [] where file.name != "." && file.name != ".." {
            names[file.name] = file.isDirectory
        }
        return names
    }

    static func localNames(in folder: String) -> [String: Bool] {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var names: [String: Bool] = [:]
        for item in items {
            names[item.lastPathComponent] = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
        return names
    }

    static func removeRemote(_ path: String, on shell: NSRemoteShell) -> Bool {
        shell.requestDelete(forFileAndWait: path, withProgressBlock: { _ in }, withContinuationHandler: { true })
    }

    /// To the Trash, so what was replaced can be put back.
    static func removeLocal(_ path: String) -> Bool {
        (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)) != nil
    }

    /// Copies from one folder on this Mac to another, as Finder does: a copy
    /// that replaces sends what was there to the Trash first, a folder whole.
    public static func copyLocally(_ paths: [String], into folder: String, _ collision: TransferJob.Collision) throws {
        var existing = localNames(in: folder)
        for path in paths {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            let name = (path as NSString).lastPathComponent
            let taken = existing[name] != nil
            guard let place = place(name, isDirectory: isDirectory.boolValue, among: &existing, collision) else { continue }
            let target = (folder as NSString).appendingPathComponent(place.name)
            // Replacing an item with itself would only send it to the Trash.
            if target == path { continue }
            if taken, collision == .replace {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: nil)
            }
            try FileManager.default.copyItem(atPath: path, toPath: target)
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
