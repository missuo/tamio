//
//  FileBrowser.swift
//  TamioModule
//
//  One pane of the SFTP page: a folder on this Mac or on a server, with back
//  and forward history. A server's browser has an SFTP connection of its own,
//  so browsing goes on while files transfer on theirs.
//

import Foundation
import NSRemoteShell

public struct FileEntry: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isLink: Bool
    public let size: Int64?
    public let modified: Date?
    /// "drwxr-xr-x", as ls shows it.
    public let permissions: String

    /// "folder", "text", "image", "archive"… from the extension.
    public var kind: String {
        if isDirectory { return "folder" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "": return isLink ? "alias" : "file"
        case "txt", "md", "log", "conf", "cfg", "ini", "yml", "yaml", "json", "toml", "xml", "csv": return ext
        case "sh", "bash", "zsh", "py", "rb", "js", "ts", "go", "rs", "swift", "c", "h", "cpp", "java", "php": return "script"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "image"
        case "zip", "gz", "tgz", "bz2", "xz", "zst", "tar", "7z", "rar": return "archive"
        case "mp4", "mov", "mkv", "webm": return "video"
        case "mp3", "flac", "wav", "m4a": return "audio"
        case "pdf": return "pdf"
        default: return ext
        }
    }
}

@MainActor
public class FileBrowser: ObservableObject, Identifiable {
    public let id = UUID()

    @Published public fileprivate(set) var path: String
    @Published public private(set) var entries: [FileEntry] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public private(set) var back: [String] = []
    @Published public private(set) var forward: [String] = []

    init(path: String) {
        self.path = path
    }

    /// "Local", or the server's name.
    public var title: String { "" }
    /// The server, nil on this Mac.
    public var machine: RDMachine? { nil }

    public func open(_ path: String) {
        let target = Self.normalize(path)
        guard target != self.path else { return reload() }
        back.append(self.path)
        forward.removeAll()
        self.path = target
        reload()
    }

    public func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(path)
        path = previous
        reload()
    }

    public func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(path)
        path = next
        reload()
    }

    public func goUp() {
        guard path != "/" else { return }
        open((path as NSString).deletingLastPathComponent)
    }

    /// Where the browser begins, when it is only known once connected (a
    /// server's home folder); nil to stay where it is.
    func startingPath() async -> String? { nil }
    private var started = false

    public func reload() {
        if !started {
            started = true
            isLoading = true
            Task {
                if let start = await startingPath(), start != path { path = start }
                reload()
            }
            return
        }
        let requested = path
        isLoading = true
        Task {
            let result = await list(requested)
            guard requested == path else { return }
            isLoading = false
            switch result {
            case let .success(list):
                error = nil
                entries = list.sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            case let .failure(failure):
                error = failure.message
                entries = []
            }
        }
    }

    // Overridden by the local and remote browsers.
    func list(_: String) async -> Result<[FileEntry], FileBrowserError> { .success([]) }
    public func makeFolder(named _: String) async -> FileBrowserError? { nil }
    public func rename(_ entry: FileEntry, to name: String) async -> FileBrowserError? {
        await move(entry.path, to: child(name))
    }
    /// Moves a file or folder to another path on the same side.
    public func move(_: String, to _: String) async -> FileBrowserError? { nil }
    public func delete(_: [FileEntry]) async -> FileBrowserError? { nil }

    static func normalize(_ path: String) -> String {
        let standard = (path as NSString).standardizingPath
        return standard.isEmpty ? "/" : standard
    }

    public func child(_ name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }
}

public struct FileBrowserError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

// MARK: - This Mac

@MainActor
public final class LocalBrowser: FileBrowser {
    public override init(path: String = NSHomeDirectory()) {
        super.init(path: path)
    }

    override public var title: String { String(localized: "Local") }

    override func list(_ path: String) async -> Result<[FileEntry], FileBrowserError> {
        await Task.detached {
            let manager = FileManager.default
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            do {
                // Hidden files are listed; the pane shows them when asked.
                let urls = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
                return .success(urls.map { item in
                    let values = try? item.resourceValues(forKeys: Set(keys))
                    let attributes = try? manager.attributesOfItem(atPath: item.path)
                    let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                    let isDirectory = values?.isDirectory ?? false
                    return FileEntry(
                        name: item.lastPathComponent,
                        path: item.path,
                        isDirectory: isDirectory,
                        isLink: values?.isSymbolicLink ?? false,
                        size: isDirectory ? nil : (values?.fileSize).map(Int64.init),
                        modified: values?.contentModificationDate,
                        permissions: Self.permissions(mode, directory: isDirectory)
                    )
                })
            } catch {
                return .failure(FileBrowserError(error.localizedDescription))
            }
        }.value
    }

    nonisolated static func permissions(_ mode: UInt16, directory: Bool) -> String {
        let marks = Array("rwxrwxrwx")
        var text = directory ? "d" : "-"
        for bit in 0 ..< 9 {
            text.append(mode & (1 << (8 - bit)) != 0 ? marks[bit] : "-")
        }
        return text
    }

    override public func makeFolder(named name: String) async -> FileBrowserError? {
        do {
            try FileManager.default.createDirectory(atPath: child(name), withIntermediateDirectories: false)
            reload()
            return nil
        } catch {
            return FileBrowserError(error.localizedDescription)
        }
    }

    override public func move(_ source: String, to target: String) async -> FileBrowserError? {
        do {
            try FileManager.default.moveItem(atPath: source, toPath: target)
            reload()
            return nil
        } catch {
            return FileBrowserError(error.localizedDescription)
        }
    }

    /// To the Trash, so it can be put back.
    override public func delete(_ entries: [FileEntry]) async -> FileBrowserError? {
        defer { reload() }
        for entry in entries {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
            } catch {
                return FileBrowserError(error.localizedDescription)
            }
        }
        return nil
    }
}

// MARK: - A server

@MainActor
public final class RemoteBrowser: FileBrowser {
    public let server: RDMachine
    @Published public private(set) var connected = false
    @Published public private(set) var connecting = false

    nonisolated(unsafe) private let shell: NSRemoteShell
    private let identity: RDIdentity?
    nonisolated private static let queue = DispatchQueue(label: "sb.moe.tamio.sftp.browse", attributes: .concurrent)

    public init(machine: RDMachine) {
        server = machine
        identity = TamioStore.shared.associatedIdentity(for: machine)
        shell = NSRemoteShell.configured(for: machine, timeout: TamioStore.shared.timeoutNumber)
        super.init(path: machine.startsInHomeFolder ? "/" : machine.fileTransferLoginPath)
    }

    /// The home folder of the user Tamio signs in as, unless the server
    /// names another start folder.
    override func startingPath() async -> String? {
        guard server.startsInHomeFolder else { return nil }
        let result = await onShell { shell -> String in
            var output = ""
            let lock = NSLock()
            shell.beginExecute(
                withCommand: "printf '%s' \"$HOME\"",
                withTimeout: NSNumber(value: 10),
                withOnCreate: {},
                withOutput: { chunk in
                    lock.lock()
                    output += chunk
                    lock.unlock()
                },
                withContinuationHandler: nil
            )
            lock.lock()
            defer { lock.unlock() }
            return output
        }
        guard case let .success(output) = result else { return nil }
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return home.hasPrefix("/") ? home : nil
    }

    override public var title: String { server.name }
    override public var machine: RDMachine? { server }

    deinit {
        let shell = shell
        Self.queue.async {
            shell.requestDisconnectAndWait()
            shell.destroyPermanently()
        }
    }

    /// Runs `work` on the connection, connecting first when needed.
    private func onShell<T: Sendable>(_ work: @escaping @Sendable (NSRemoteShell) -> T) async -> Result<T, FileBrowserError> {
        if !connected { connecting = true }
        nonisolated(unsafe) let shell = shell
        let identity = identity
        let machine = server
        let result: Result<T, FileBrowserError> = await withCheckedContinuation { continuation in
            Self.queue.async {
                if !(shell.isConnected && shell.isAuthenticated) {
                    let outcome = shell.connectAndAuthenticate(identity: identity, autoIdentities: TamioStore.shared.workerIdentitiesForAutoAuth, for: machine)
                    guard outcome == .success else {
                        let message = shell.hostKeyRefusal ?? (outcome == .connectFailed
                            ? shell.getLastError() ?? String(localized: "Could not reach \(machine.remoteAddress):\(machine.remotePort).")
                            : String(localized: "Could not sign in as \(machine.loginUsername(with: identity))."))
                        return continuation.resume(returning: .failure(FileBrowserError(message)))
                    }
                }
                if !shell.isConnectedFileTransfer {
                    shell.requestConnectFileTransferAndWait()
                    guard shell.isConnectedFileTransfer else {
                        return continuation.resume(returning: .failure(FileBrowserError(String(localized: "\(machine.name) does not offer SFTP. Enable its sftp subsystem in sshd_config."))))
                    }
                }
                continuation.resume(returning: .success(work(shell)))
            }
        }
        connecting = false
        if case .success = result { connected = true }
        return result
    }

    override func list(_ path: String) async -> Result<[FileEntry], FileBrowserError> {
        let result = await onShell { shell -> [FileEntry]? in
            shell.requestFileList(at: path).map { files in
                files.filter { $0.name != "." && $0.name != ".." }.map { file in
                    FileEntry(
                        name: file.name,
                        path: (path as NSString).appendingPathComponent(file.name),
                        isDirectory: file.isDirectory,
                        isLink: file.isLink,
                        size: file.isDirectory ? nil : file.size?.int64Value,
                        modified: file.modificationDate,
                        permissions: file.permissionDescription
                    )
                }
            }
        }
        switch result {
        case let .success(list):
            guard let list else { return .failure(FileBrowserError(String(localized: "\(path) could not be read."))) }
            return .success(list)
        case let .failure(error):
            return .failure(error)
        }
    }

    override public func makeFolder(named name: String) async -> FileBrowserError? {
        let target = child(name)
        let result = await onShell { $0.requestCreateDirAndWait(target) }
        reload()
        if case .success(false) = result { return FileBrowserError(String(localized: "\(name) could not be made.")) }
        if case let .failure(error) = result { return error }
        return nil
    }

    override public func move(_ source: String, to target: String) async -> FileBrowserError? {
        let result = await onShell { $0.requestRenameFileAndWait(source, withNewPath: target) }
        reload()
        if case .success(false) = result { return FileBrowserError(String(localized: "\((source as NSString).lastPathComponent) could not be moved.")) }
        if case let .failure(error) = result { return error }
        return nil
    }

    override public func delete(_ entries: [FileEntry]) async -> FileBrowserError? {
        let paths = entries.map(\.path)
        let result = await onShell { shell in
            paths.allSatisfy { shell.requestDelete(forFileAndWait: $0, withProgressBlock: { _ in }, withContinuationHandler: { true }) }
        }
        reload()
        if case .success(false) = result { return FileBrowserError(String(localized: "Not everything could be deleted.")) }
        if case let .failure(error) = result { return error }
        return nil
    }
}
