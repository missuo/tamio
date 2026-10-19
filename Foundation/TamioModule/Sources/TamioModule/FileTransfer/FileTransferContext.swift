//
//  FileTransferContext.swift
//  TamioModule
//
//  Shared SFTP session context, previously duplicated between the
//  macOS and iOS apps. Platform-specific UI is delegated through
//  FileTransferInterface.
//

import NSRemoteShell
import SwiftUI

public class FileTransferContext: ObservableObject, Identifiable, Equatable {
    public var id: UUID = .init()

    public var navigationTitle: String {
        machine.name
    }

    @Published public var navigationSubtitle: String = ""

    public let machine: RDMachine
    public let identity: RDIdentity?
    public var shell: NSRemoteShell = .init()
    public var firstConnect: Bool = true
    public var destroyedSession: Bool = false {
        didSet {
            shell.destroyPermanently()
        }
    }

    // not really represents the connection status in real time
    // but we check and tag this each time we operate
    @Published public var connected: Bool = false
    @Published public var processConnection: Bool = false

    /// Where the session is between bootstrap and shutdown. Views branch
    /// on this instead of matching `currentHint`, so the hint text below
    /// stays display-only and a copy edit cannot silently change behavior.
    public enum ConnectionPhase {
        /// Fresh context; the first connect attempt has not run yet.
        case idle
        /// A connect attempt is in flight.
        case connecting
        /// The session is up; file transfer is available.
        case connected
        /// The session ended: connect failed, the link dropped, or the
        /// user closed it.
        case closed
    }

    @Published public private(set) var connectionPhase: ConnectionPhase = .idle

    @Published public var currentDir: String = "/" {
        didSet {
            navigationSubtitle = currentDir
            // let the ui call us
        }
    }

    @Published public var currentFileList: [RemoteFile] = []
    public var currentUrl: URL {
        URL(fileURLWithPath: currentDir)
    }

    @Published public var isProgressRunning: Bool = true { // bootstrap set
        didSet {
            debugPrint("sftp session progress setting \(isProgressRunning)")
        }
    }

    @Published public var totalProgress: Progress = .init()
    @Published public var currentProcessingFile: String = ""
    @Published public var currentProgress: Progress = .init()
    @Published public var currentHint: String = ""
    @Published public var currentSpeed: Int = 0
    @Published public var currentProgressCancelable = false
    private let progressContinuationLock = NSLock()
    private var progressContinuation = false
    /// Written on the main thread by the cancel button, read on the transfer
    /// threads by the continuation handlers; the lock keeps that safe.
    public var continueCurrentProgress: Bool {
        get {
            progressContinuationLock.lock()
            defer { progressContinuationLock.unlock() }
            return progressContinuation
        }
        set {
            progressContinuationLock.lock()
            defer { progressContinuationLock.unlock() }
            progressContinuation = newValue
        }
    }

    public struct RemoteFile: Identifiable, Equatable, Hashable {
        public var id: RemoteFile { self }
        public let base: URL
        public let name: String
        public let fstat: NSRemoteFile

        public init(base: URL, name: String, fstat: NSRemoteFile) {
            self.base = base
            self.name = name
            self.fstat = fstat
        }
    }

    // MARK: SHELL CONTEXT -

    public init(machine: RDMachine, identity: RDIdentity? = nil) {
        self.machine = machine
        self.identity = identity
        currentDir = machine.startsInHomeFolder ? "/" : machine.fileTransferLoginPath
        DispatchQueue.global().async {
            self.processBootstrap()
        }
    }

    deinit {
        shell.destroyPermanently()
    }

    public static func == (lhs: FileTransferContext, rhs: FileTransferContext) -> Bool {
        lhs.id == rhs.id
    }

    func setupShellData() {
        // Called on the session's worker queue; reads the worker snapshot.
        shell.applyConnection(for: machine, timeout: TamioStore.shared.workerTimeoutNumber)
    }

    public func putInformation(_ str: String) {
        onMainThread {
            self.currentHint = str
        }
    }

    public func processBootstrap() {
        onMainThread {
            guard self.firstConnect else { return }
            self.firstConnect = false
            guard TamioStore.shared.openInterfaceAutomatically else { return }
            FileTransferInterface.uiHandler.autoOpenInterface(self)
        }
        DispatchQueue.global().async {
            self.callConnect()
        }
    }

    func callConnect() {
        putInformation(String(localized: "Connecting..."))
        onMainThread {
            self.processConnection = true
            self.connectionPhase = .connecting
        }
        defer { onMainThread { self.processConnection = false } }
        setupShellData()

        debugPrint("\(self) \(#function) \(machine.id)")
        let result = shell.connectAndAuthenticate(
            identity: identity,
            autoIdentities: TamioStore.shared.workerIdentitiesForAutoAuth,
            for: machine
        ) { [self] hintText in
            putInformation(hintText)
        }
        switch result {
        case .success:
            break
        case .connectFailed:
            putInformation(shell.hostKeyRefusal ?? shell.getLastError() ?? String(localized: "Unable to connect for \(machine.remoteAddress):\(machine.remotePort)"))
            onMainThread { self.processShutdown() }
            return
        case .authenticateFailed:
            putInformation(String(localized: "Failed to authenticate connection, did you forget to add identity or enable auto authentication?"))
            onMainThread { self.processShutdown() }
            return
        }

        shell.requestConnectFileTransferAndWait()
        guard shell.isConnectedFileTransfer else {
            putInformation(String(localized: "Failed to setup file transfer protocol"))
            onMainThread { self.processShutdown() }
            return
        }

        debugPrint("sftp session for \(machine.name) is now connected")
        // don't tag progress because we will tag it at loadCurrentFileList
        onMainThread {
            self.connected = true
            self.connectionPhase = .connected
        }
        loadCurrentFileList()
    }

    public func processShutdown() {
        putInformation(String(localized: "Connection Closed"))
        // you are in charge to cancel sftp operation at interface level
        // because sftp operations are in control blocks which are not canceled during fly
        // I may add a control later tho
        onMainThread {
            self.connected = false
            self.currentFileList = []
            self.processConnection = false
            self.isProgressRunning = false
            self.connectionPhase = .closed
        }
        DispatchQueue.global().async { [weak shell] in
            shell?.requestDisconnectAndWait()
        }
    }

    public func connectionAvailableCheckPassed() -> Bool {
        guard shell.isConnected,
              shell.isAuthenticated,
              shell.isConnectedFileTransfer
        else {
            processShutdown()
            return false
        }
        resetCurrentProgress()
        return true
    }

    func resetCurrentProgress() {
        onMainThread { [self] in
            totalProgress = .init()
            currentProcessingFile = ""
            currentProgress = .init()
            currentHint = ""
            currentSpeed = 0
            currentProgressCancelable = false
        }
    }

    public func loadCurrentFileList() {
        guard connectionAvailableCheckPassed() else { return }
        let currentDir = currentDir
        let currentUrl = currentUrl
        DispatchQueue.global().async { [self] in
            putInformation(String(localized: "Loading... \(currentDir)"))
            onMainThread { self.isProgressRunning = true }
            let files = shell.requestFileList(at: currentDir)
            var builder = [RemoteFile]()
            for file in files ?? [] {
                builder.append(.init(base: currentUrl, name: file.name, fstat: file))
            }
            putInformation(String(localized: "Load Complete"))
            onMainThread {
                // A navigation that happened meanwhile issues its own load;
                // this one's result belongs to a directory already left.
                guard self.currentDir == currentDir else { return }
                self.isProgressRunning = false
                self.currentFileList = builder
            }
        }
    }

    public func createFolder(with name: String) {
        guard connectionAvailableCheckPassed() else { return }
        let url = currentUrl.appendingPathComponent(name)
        DispatchQueue.global().async { [self] in
            putInformation(String(localized: "Creating Folder \(url.path)..."))
            onMainThread { self.isProgressRunning = true }
            let done = shell.requestCreateDirAndWait(url.path)
            if done {
                putInformation(String(localized: "Folder Created"))
            } else {
                let error = shell.getLastFileTransferError()
                FileTransferInterface.uiHandler.presentError(String(localized: "Failed to Create"))
                print("SFTP \(machine.name) Error: \(error ?? "Unknown")")
            }
            loadCurrentFileList()
        }
    }

    public func navigate(path: String) {
        guard connectionAvailableCheckPassed() else { return }
        currentDir = path
        loadCurrentFileList()
    }

    public func upload(urls: [URL]) {
        guard connectionAvailableCheckPassed() else { return }
        let base = currentUrl
        continueCurrentProgress = true
        DispatchQueue.global().async { [self] in
            onMainThread {
                self.isProgressRunning = true
                self.currentProgressCancelable = true
            }
            let total = urls.count
            var current = 0
            putInformation(String(localized: "Uploading..."))
            for url in urls {
                defer { current += 1 }
                onMainThread {
                    let progress = Progress(totalUnitCount: Int64(total))
                    progress.completedUnitCount = Int64(current)
                    self.totalProgress = progress
                }
                let done = shell.requestUpload(
                    forFileAndWait: url.path,
                    toDirectory: base.path
                ) { file, progress, speed in
                    self.currentProcessingFile = file
                    self.currentProgress = progress
                    self.currentSpeed = speed
                } withContinuationHandler: {
                    self.continueCurrentProgress
                }
                guard done else {
                    let error = shell.getLastFileTransferError()
                    FileTransferInterface.uiHandler.presentError(String(localized: "Error Occurred"))
                    print("SFTP \(machine.name) Error: \(error ?? "Unknown")")
                    break
                }
            }
            putInformation(String(localized: "Upload Completed"))
            loadCurrentFileList()
        }
    }

    public func rename(from: URL, to: URL) {
        guard connectionAvailableCheckPassed() else { return }
        DispatchQueue.global().async { [self] in
            putInformation(String(localized: "Renaming..."))
            onMainThread { self.isProgressRunning = true }
            let done = shell.requestRenameFileAndWait(from.path, withNewPath: to.path)
            if done {
                putInformation(String(localized: "Renamed Successfully"))
            } else {
                let error = shell.getLastFileTransferError()
                FileTransferInterface.uiHandler.presentError(String(localized: "Failed to Rename"))
                print("SFTP \(machine.name) Error: \(error ?? "Unknown")")
            }
            loadCurrentFileList()
        }
    }

    public func delete(item: URL) {
        guard connectionAvailableCheckPassed() else { return }
        continueCurrentProgress = true
        DispatchQueue.global().async { [self] in
            onMainThread {
                self.isProgressRunning = true
                self.currentProgressCancelable = true
                self.currentProcessingFile = item.path
            }
            putInformation(String(localized: "Deleting..."))
            let done = shell.requestDelete(
                forFileAndWait: item.path
            ) { file in
                self.currentProcessingFile = file
            } withContinuationHandler: {
                self.continueCurrentProgress
            }
            if done {
                putInformation(String(localized: "Delete Completed"))
            } else {
                let error = shell.getLastFileTransferError()
                FileTransferInterface.uiHandler.presentError(String(localized: "Error Occurred"))
                print("SFTP \(machine.name) Error: \(error ?? "Unknown")")
            }
            loadCurrentFileList()
        }
    }

    public func download(from: URL, toDir: URL) {
        let fromPath = from.path
        var to = toDir.path
        if !to.hasSuffix("/") { to += "/" }
        // now let's put that file name into to
        to += from.lastPathComponent
        let toBase = URL(fileURLWithPath: to)
        let ext = toBase.pathExtension
        var duplicate = 1
        while FileManager.default.fileExists(atPath: to) {
            duplicate += 1
            to = toBase.deletingPathExtension().path + ".\(duplicate)"
            if !ext.isEmpty { to += ".\(ext)" }
        }
        guard connectionAvailableCheckPassed() else { return }
        continueCurrentProgress = true
        DispatchQueue.global().async { [self] in
            onMainThread {
                self.isProgressRunning = true
                self.currentProgressCancelable = true
            }
            putInformation(String(localized: "Downloading..."))
            let done = shell.requestDownload(
                fromFileAndWait: fromPath,
                toLocalPath: to
            ) { file, progress, speed in
                self.currentProcessingFile = file
                self.currentProgress = progress
                self.currentSpeed = speed
            } withContinuationHandler: {
                self.continueCurrentProgress
            }
            if done {
                putInformation(String(localized: "Download Completed"))
                onMainThread {
                    FileTransferInterface.uiHandler.downloadCompleted()
                }
            } else {
                let error = shell.getLastFileTransferError()
                FileTransferInterface.uiHandler.presentError(String(localized: "Error Occurred"))
                print("SFTP \(machine.name) Error: \(error ?? "Unknown")")
            }
            loadCurrentFileList()
        }
    }
}
