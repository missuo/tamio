//
//  TerminalContext.swift
//  TamioModule
//
//  Shared SSH terminal session context, previously duplicated between the
//  macOS and iOS apps. The renderer stays in the apps and is injected as a
//  TerminalSessionSurface; interface presentation goes through
//  TerminalInterface.
//

import Foundation
import NSRemoteShell
import SwiftUI

/// The terminal renderer a session drives, implemented in the apps over
/// TamioTerminalView so TamioModule never links the renderer.
public protocol TerminalSessionSurface: AnyObject {
    func write(_ string: String)
    func setupBellChain(_ callback: @escaping () -> Void)
    func setupBufferChain(_ callback: @escaping (String) -> Void)
    func setupTitleChain(_ callback: @escaping (String) -> Void)
    func setupSizeChain(_ callback: @escaping (CGSize) -> Void)
}

open class TerminalContext: ObservableObject, Identifiable, Equatable {
    public var id: UUID = .init()

    public var navigationTitle: String {
        switch remoteType {
        case .machine: return machine.shortDescription(withComment: false)
        case .command: return command?.command ?? String(localized: "Unknown Command")
        }
    }

    public var firstConnect = true
    /// Typed once the shell is open, after the server's startup snippet
    /// (a container's logs, a shell in it).
    public var initialCommand: String?
    @Published public var destroyedSession = false {
        didSet {
            if destroyedSession {
                shell.destroyPermanently()
            }
        }
    }

    @Published public var navigationSubtitle: String = ""

    /// The folder the shell last reported, when it reports one.
    @Published public private(set) var workingDirectory: String?
    /// Main thread only, like the writes to the surface.
    private var directoryReader = WorkingDirectoryReader()

    private var title: String = "" {
        didSet {
            onMainThread {
                self.navigationSubtitle = self.title
            }
        }
    }

    public enum RemoteType {
        case machine
        case command
    }

    public let remoteType: RemoteType

    public let machine: RDMachine
    public let command: SSHCommandReader?
    public var shell: NSRemoteShell = .init()

    /// The renderer this session writes output to and takes input from.
    public let surface: TerminalSessionSurface

    // MARK: - SHELL CONTEXT

    public var closed: Bool { !continueDecision }

    @Published public var interfaceToken: UUID = .init()
    @Published public var interfaceDisabled: Bool = false

    public static let defaultTerminalSize = CGSize(width: 80, height: 40)

    // The parser thread writes terminalSize and the shell IO thread reads
    // it; main and the bootstrap thread write continueDecision and the IO
    // thread reads it. One lock covers both, as bufferAccessLock does
    // _dataBuffer. Side effects run outside the critical section.
    private let stateAccessLock = NSLock()
    private var _terminalSize: CGSize = defaultTerminalSize
    private var _continueDecision: Bool = true

    public var terminalSize: CGSize {
        get {
            stateAccessLock.lock()
            defer { stateAccessLock.unlock() }
            return _terminalSize
        }
        set {
            stateAccessLock.lock()
            _terminalSize = newValue
            stateAccessLock.unlock()
            shell.explicitRequestStatusPickup()
        }
    }

    private var _dataBuffer: String = ""
    private var bufferAccessLock = NSLock()

    public func getBuffer() -> String {
        bufferAccessLock.lock()
        defer { bufferAccessLock.unlock() }
        let copy = _dataBuffer
        _dataBuffer = ""
        return copy
    }

    public func insertBuffer(_ str: String) {
        bufferAccessLock.lock()
        defer { bufferAccessLock.unlock() }
        guard !closed else { return }
        _dataBuffer += str
        Self.queue.async { [weak self] in
            self?.shell.explicitRequestStatusPickup()
        }
    }

    public var continueDecision: Bool {
        get {
            stateAccessLock.lock()
            defer { stateAccessLock.unlock() }
            return _continueDecision
        }
        set {
            stateAccessLock.lock()
            _continueDecision = newValue
            stateAccessLock.unlock()
            onMainThread {
                self.interfaceDisabled = !self.continueDecision
            }
        }
    }

    // MARK: SHELL CONTEXT -

    private static let queue = DispatchQueue(
        label: "sb.moe.tamio.terminal",
        attributes: .concurrent
    )

    public init(machine: RDMachine, surface: TerminalSessionSurface) {
        self.machine = machine
        command = nil
        remoteType = .machine
        title = machine.name
        self.surface = surface
        Self.queue.async {
            self.processBootstrap()
        }
    }

    public init(command: SSHCommandReader, surface: TerminalSessionSurface) {
        machine = RDMachine(
            remoteAddress: command.remoteAddress,
            remotePort: command.remotePort,
            name: command.remoteAddress,
            group: "SSHCommandReader",
            associatedIdentity: nil
        )
        self.command = command
        title = command.command
        remoteType = .command
        self.surface = surface
        Self.queue.async {
            self.processBootstrap()
        }
    }

    public func setupShellData() {
        // Called on the session's worker queue; reads the worker snapshot.
        shell.applyConnection(for: machine, timeout: TamioStore.shared.workerTimeoutNumber)
    }

    public static func == (lhs: TerminalContext, rhs: TerminalContext) -> Bool {
        lhs.id == rhs.id
    }

    public func putInformation(_ str: String) {
        surface.write(str + "\r\n")
    }

    public func processBootstrap() {
        defer {
            onMainThread { self.processShutdown(exitFromShell: true) }
        }

        onMainThread {
            guard self.firstConnect else { return }
            self.firstConnect = false
            guard TamioStore.shared.openInterfaceAutomatically else { return }
            TerminalInterface.uiHandler.autoOpenInterface(self)
        }

        setupShellData()

        debugPrint("\(self) \(#function) \(machine.id)")
        putInformation(String(localized: "[*] Creating Connection"))
        continueDecision = true

        surface.setupBellChain {
            debugPrint("terminal bell")
        }
        surface.setupBufferChain { [weak self] buffer in
            self?.insertBuffer(buffer)
        }
        surface.setupTitleChain { [weak self] str in
            self?.title = str
        }
        surface.setupSizeChain { [weak self] size in
            self?.terminalSize = size
        }

        let identity: RDIdentity?
        if machine.associatedIdentity != nil {
            guard let resolved = TamioStore.shared.workerAssociatedIdentity(for: machine) else {
                putInformation(String(localized: "Malformed machine or identity data"))
                return
            }
            identity = resolved
        } else {
            identity = nil
        }

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
            if let refusal = shell.hostKeyRefusal {
                putInformation(refusal.replacingOccurrences(of: "\n", with: "\r\n"))
            } else if let proxyFailure = shell.getLastError() {
                putInformation(proxyFailure.replacingOccurrences(of: "\n", with: "\r\n"))
            } else {
                putInformation(String(localized: "Unable to connect for \(machine.remoteAddress):\(machine.remotePort)"))
            }
            return
        case .authenticateFailed:
            putInformation(String(localized: "Failed to authenticate connection"))
            putInformation(String(localized: "Did you forget to add identity or enable auto authentication?"))
            return
        }

        onMainThread {
            guard self.remoteType == .machine else {
                return
            }
            var read = TamioStore.shared.machineGroup[self.machine.id]
            if read.isNotPlaceholder() {
                read.lastBanner = self.shell.remoteBanner ?? String(localized: "No Banner")
                TamioStore.shared.machineGroup[self.machine.id] = read
            }
        }

        let startupSnippet = remoteType == .machine ? machine.startupSnippet : nil
        let initialCommand = initialCommand
        // First, so a snippet that opens another shell (a container's) does
        // not take it.
        let hook = remoteType == .machine && machine.shellIntegration ? ShellIntegration.hook : ""
        shell.begin(withTerminalType: "xterm") { [weak self] in
            debugPrint("channel open")
            // The server's startup snippet, then the command the terminal was
            // opened for, are typed once the shell is there, as if the user
            // had typed them.
            onMainThread {
                let snippet = startupSnippet.map { TamioStore.shared.snippetGroup[$0].code } ?? ""
                for code in [hook, snippet, initialCommand ?? ""] where !code.isEmpty {
                    let typed = code.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
                    self?.insertBuffer(typed.hasSuffix("\r") ? typed : typed + "\r")
                }
            }
        } withTerminalSize: { [weak self] in
            var size = self?.terminalSize ?? TerminalContext.defaultTerminalSize
            if size.width < 8 || size.height < 8 {
                // something went wrong
                size = TerminalContext.defaultTerminalSize
            }
            return size
        } withWriteDataBuffer: { [weak self] in
            self?.getBuffer() ?? ""
        } withOutputDataBuffer: { [weak self] output in
            // The main queue is FIFO, so writes stay ordered without
            // blocking the shell IO thread on the UI run loop.
            onMainThread {
                self?.surface.write(output)
                self?.readDirectory(in: output)
            }
        } withContinuationHandler: { [weak self] in
            self?.continueDecision ?? false
        }

        // leave loop
        debugPrint("\(self) \(#function) defer \(machine.id)")
    }

    private func readDirectory(in output: String) {
        guard let path = directoryReader.read(output), path != workingDirectory else { return }
        workingDirectory = path
        guard remoteType == .machine else { return }
        let machine = machine.id
        MainActor.assumeIsolated { TerminalDirectories.shared.report(path, for: machine) }
    }

    public func processShutdown(exitFromShell: Bool = false) {
        if exitFromShell {
            putInformation("")
            putInformation(String(localized: "[*] Connection Closed"))
        }
        if let lastError = shell.getLastError() {
            putInformation(String(localized: "[i] Last Error Provided By Backend"))
            putInformation("    " + lastError)
        }
        continueDecision = false
        let shell = shell
        Self.queue.async { [weak shell] in
            shell?.requestDisconnectAndWait()
        }
    }
}
