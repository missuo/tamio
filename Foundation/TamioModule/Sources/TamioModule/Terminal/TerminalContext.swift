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
    /// A local shell's end. Surfaces that only show SSH sessions need not
    /// implement it.
    func setupCloseChain(_ callback: @escaping () -> Void)
}

public extension TerminalSessionSurface {
    func setupCloseChain(_: @escaping () -> Void) {}
}

open class TerminalContext: ObservableObject, Identifiable, Equatable {
    public var id: UUID = .init()

    public var navigationTitle: String {
        switch remoteType {
        case .machine: return machine.shortDescription(withComment: false)
        case .command: return command?.command ?? String(localized: "Unknown Command")
        case .local: return String(localized: "This Mac")
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

    /// How many times a dropped connection is tried again, 10 s apart,
    /// before the terminal is left closed with Reconnect.
    public static let reconnectAttempts = 3
    /// A variable so a test need not wait ten seconds an attempt.
    nonisolated(unsafe) public static var reconnectDelay: TimeInterval = 10
    private var reconnectAttempt = 0
    /// Set once the user has closed the session: a drop after that is not
    /// reconnected.
    private var closedByUser = false

    /// How a session's loop ended.
    private enum Ending {
        /// The shell exited; the session was still connected.
        case exited
        case dropped
        case connectFailed
        case authFailed
    }

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
        /// A shell on this Mac, run by the terminal itself: no SSH, no shell
        /// object in use.
        case local
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
    /// Main thread only, like the size callback that sets `terminalSize`.
    private var sizeSettled = false
    private var pendingSize: DispatchWorkItem?

    /// The size the remote shell is told. A sidebar slide or a window drag
    /// changes the column count dozens of times, and each change would be a
    /// window-change request and a redraw by the shell, so a new size waits
    /// until it has held for a moment. The first goes at once, so a new
    /// terminal starts at its size.
    public var terminalSize: CGSize {
        get {
            stateAccessLock.lock()
            defer { stateAccessLock.unlock() }
            return _terminalSize
        }
        set {
            pendingSize?.cancel()
            guard sizeSettled else {
                sizeSettled = true
                commitTerminalSize(newValue)
                return
            }
            let commit = DispatchWorkItem { [weak self] in self?.commitTerminalSize(newValue) }
            pendingSize = commit
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sizeSettleDelay, execute: commit)
        }
    }

    static let sizeSettleDelay: TimeInterval = 0.12

    private func commitTerminalSize(_ size: CGSize) {
        stateAccessLock.lock()
        _terminalSize = size
        stateAccessLock.unlock()
        shell.explicitRequestStatusPickup()
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

    /// A terminal with a shell on this Mac. The surface runs the shell; this
    /// context only gives it a place among the sessions, and closes when the
    /// shell exits.
    public init(localSurface surface: TerminalSessionSurface) {
        machine = RDMachine(remoteAddress: "", remotePort: "", name: String(localized: "This Mac"), group: "Local", associatedIdentity: nil)
        command = nil
        remoteType = .local
        title = String(localized: "This Mac")
        self.surface = surface
        surface.setupTitleChain { [weak self] str in
            self?.title = str
        }
        surface.setupCloseChain { [weak self] in
            self?.continueDecision = false
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
        var ending = Ending.exited
        defer {
            onMainThread {
                self.processShutdown(exitFromShell: true)
                self.reconnectIfNeeded(after: ending)
            }
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
        if machine.associatedIdentity != nil, !machine.signsInWithoutCredentials {
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
            ending = .connectFailed
            if let refusal = shell.hostKeyRefusal {
                putInformation(refusal.replacingOccurrences(of: "\n", with: "\r\n"))
            } else if let proxyFailure = shell.getLastError() {
                putInformation(proxyFailure.replacingOccurrences(of: "\n", with: "\r\n"))
            } else {
                putInformation(String(localized: "Unable to connect for \(machine.remoteAddress):\(machine.remotePort)"))
            }
            return
        case .authenticateFailed:
            ending = .authFailed
            if machine.signsInWithoutCredentials {
                putInformation(String(localized: "The server did not let \(machine.loginUsername(with: nil)) in without a password or key."))
                if let wanted = shell.getLastError() {
                    putInformation(wanted)
                }
            } else {
                putInformation(String(localized: "Failed to authenticate connection"))
                putInformation(String(localized: "Did you forget to add identity or enable auto authentication?"))
            }
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
        // Plain xterm's terminfo has 8 colours, and zsh drops any past them:
        // zsh-autosuggestions' grey (colour 8) would show as plain text.
        shell.begin(withTerminalType: "xterm-256color") { [weak self] in
            debugPrint("channel open")
            // Connected again: a later drop gets its own attempts.
            self?.reconnectAttempt = 0
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

        // leave loop: the shell exited, leaving no error, or the session
        // went. A transport error ("transport read") is left by a socket that
        // closed, before the keepalive gets to mark the session disconnected.
        ending = shell.isConnected && shell.peekLastError() == nil ? .exited : .dropped
        debugPrint("\(self) \(#function) defer \(machine.id)")
    }

    /// A server's terminal that lost its connection, or could not connect,
    /// tries again by itself, `reconnectAttempts` times `reconnectDelay`
    /// apart. Not after the user closed it, a shell the user exited, or a
    /// sign-in the server refused: trying those again would not help.
    private func reconnectIfNeeded(after ending: Ending) {
        guard remoteType == .machine, !closedByUser, ending == .dropped || ending == .connectFailed else { return }
        guard reconnectAttempt < Self.reconnectAttempts else {
            putInformation(String(localized: "[i] Could not reconnect after \(Self.reconnectAttempts) attempts. Reconnect tries again."))
            return
        }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        putInformation(String(localized: "[i] Connection lost. Reconnecting in \(Int(Self.reconnectDelay)) s (attempt \(attempt) of \(Self.reconnectAttempts))…"))
        onMainThread(delay: Self.reconnectDelay) { [weak self] in
            // Still closed, and not by the user meanwhile; a Reconnect the
            // user clicked in between has it connected already.
            guard let self, closed, !closedByUser else { return }
            // The bootstrap runs on its own queue, as it did at first.
            nonisolated(unsafe) let session = self
            Self.queue.async { session.processBootstrap() }
        }
    }

    private func readDirectory(in output: String) {
        guard let path = directoryReader.read(output), path != workingDirectory else { return }
        workingDirectory = path
        guard remoteType == .machine else { return }
        let machine = machine.id
        MainActor.assumeIsolated { TerminalDirectories.shared.report(path, for: machine) }
    }

    public func processShutdown(exitFromShell: Bool = false) {
        if !exitFromShell { closedByUser = true }
        if remoteType == .local {
            // Nothing to disconnect: the surface owns the shell, and ends it
            // with the terminal.
            continueDecision = false
            return
        }
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
