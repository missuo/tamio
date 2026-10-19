//
//  FileTransferContext+Editing.swift
//  TamioModule
//
//  Reading a remote file as text and writing it back, for the editor. Both go
//  through the session's SFTP connection and a private temporary folder that is
//  removed afterwards.
//

import Foundation

public enum RemoteTextFileError: LocalizedError, Equatable {
    case notConnected
    case tooLarge(bytes: Int64, limit: Int64)
    case notText
    case transfer(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to the server.")
        case let .tooLarge(bytes, limit):
            let formatter = ByteCountFormatter()
            return String(localized: "This file is \(formatter.string(fromByteCount: bytes)); files up to \(formatter.string(fromByteCount: limit)) open in the editor. Download it instead.")
        case .notText:
            return String(localized: "This file isn't UTF-8 text, so it can't be edited here. Download it instead.")
        case let .transfer(message):
            return message
        }
    }
}

public extension FileTransferContext {
    /// Files larger than this are downloaded rather than opened in the editor.
    static let editableSizeLimit: Int64 = 4 * 1024 * 1024

    /// Reads a remote file as UTF-8 text.
    func readText(at remotePath: String) async throws -> String {
        guard connected else { throw RemoteTextFileError.notConnected }
        let folder = try Self.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent(URL(fileURLWithPath: remotePath).lastPathComponent)
        // NSRemoteShell serializes its own work; the rest of the transfer code
        // also calls it from background queues.
        nonisolated(unsafe) let shell = shell
        // Asked first, so a file that is too large is never fetched. The
        // answer follows a link to the file it names.
        let size: Int64? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: shell.requestFileInfo(at: remotePath)?.size?.int64Value)
            }
        }
        if let size, size > Self.editableSizeLimit {
            throw RemoteTextFileError.tooLarge(bytes: size, limit: Self.editableSizeLimit)
        }
        let succeeded = await Self.background {
            shell.requestDownload(fromFileAndWait: remotePath, toLocalPath: local.path) { _, _, _ in
            } withContinuationHandler: {
                true
            }
        }
        guard succeeded else {
            throw RemoteTextFileError.transfer(shell.getLastFileTransferError() ?? String(localized: "Couldn't read \(remotePath)."))
        }
        let data = try Data(contentsOf: local)
        guard Int64(data.count) <= Self.editableSizeLimit else {
            throw RemoteTextFileError.tooLarge(bytes: Int64(data.count), limit: Self.editableSizeLimit)
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw RemoteTextFileError.notText
        }
        return text
    }

    /// Replaces a remote file's contents with `text` (UTF-8). An existing file
    /// keeps its permissions.
    func writeText(_ text: String, to remotePath: String) async throws {
        guard connected else { throw RemoteTextFileError.notConnected }
        let folder = try Self.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let remote = URL(fileURLWithPath: remotePath)
        // Upload keeps the local file's name, so the scratch copy carries the remote one.
        let local = folder.appendingPathComponent(remote.lastPathComponent)
        try Data(text.utf8).write(to: local)
        let directory = remote.deletingLastPathComponent().path
        // NSRemoteShell serializes its own work; the rest of the transfer code
        // also calls it from background queues.
        nonisolated(unsafe) let shell = shell
        let succeeded = await Self.background {
            shell.requestUpload(forFileAndWait: local.path, toDirectory: directory) { _, _, _ in
            } withContinuationHandler: {
                true
            }
        }
        guard succeeded else {
            throw RemoteTextFileError.transfer(shell.getLastFileTransferError() ?? String(localized: "Couldn't save \(remotePath)."))
        }
    }

    private static func makeScratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TamioEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Runs a blocking shell call off the main thread.
    private static func background(_ work: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
