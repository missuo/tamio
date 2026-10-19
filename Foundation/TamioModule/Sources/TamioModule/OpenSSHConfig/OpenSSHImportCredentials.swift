import Darwin
import Foundation

struct OpenSSHImportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum OpenSSHImportCredentials {
    static let sourceKey = "openssh.identity.path"
    static let maximumKeyBytes = 1024 * 1024

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func publicMaterial(_ key: String) -> String? {
        let parts = key.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"].contains(String(parts[0])),
              let data = Data(base64Encoded: String(parts[1])), !data.isEmpty
        else { return nil }
        return "\(parts[0]) \(parts[1])"
    }

    /// Only public sidecars are consulted during review. A source-path match is
    /// a suggestion, not permission to open or copy that private file.
    static func matchingIdentities(paths: [String], identities: [RDIdentity]) -> [RDIdentity] {
        var publicKeys = Set<String>()
        let canonical = Set(paths.map(canonicalPath))
        for path in paths {
            if let text = try? readRegularFile(canonicalPath(path) + ".pub", limit: 64 * 1024),
               let key = publicMaterial(text) { publicKeys.insert(key) }
        }
        return identities.filter { identity in
            guard !identity.isPrivate, identity.hasCredentials else { return false }
            if let path = identity.attachment[sourceKey], canonical.contains(canonicalPath(path)) { return true }
            return publicMaterial(identity.publicKey).map { publicKeys.contains($0) } ?? false
        }
    }

    static func importKey(path: String, passphrase: String, identities: [RDIdentity]) throws -> RDIdentity {
        let source = canonicalPath(path)
        let privateKey = try readRegularFile(source, limit: maximumKeyBytes)
        guard privateKey.contains("-----BEGIN "), privateKey.contains("PRIVATE KEY-----"), !privateKey.contains("\0") else {
            throw OpenSSHImportError(String(localized: "The selected file is not a supported private key."))
        }
        // Validate a stable copy, never a path which may change while keygen
        // reads it. The passphrase is neither an argument nor written to disk.
        let publicKey = try derivePublicKey(privateKey: privateKey, passphrase: passphrase)
        guard let material = publicMaterial(publicKey) else {
            throw OpenSSHImportError(String(localized: "This private key uses an algorithm Tamio does not support."))
        }
        if let existing = identities.first(where: {
            !$0.isPrivate && !$0.privateKey.isEmpty &&
                ($0.privateKey == privateKey || publicMaterial($0.publicKey) == material)
        }) { return existing }
        var identity = RDIdentity(password: passphrase, privateKey: privateKey, publicKey: publicKey, authenticAutomatically: false,
                                  attachment: [sourceKey: source])
        identity.name = URL(fileURLWithPath: source).lastPathComponent
        return identity
    }

    static func readRegularFile(_ path: String, limit: Int) throws -> String {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw OpenSSHImportError(String(localized: "The selected key file could not be read.")) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= limit else {
            throw OpenSSHImportError(String(localized: "The key must be a regular file smaller than 1 MB."))
        }
        guard let data = try handle.read(upToCount: limit + 1), data.count <= limit,
              let text = String(data: data, encoding: .utf8)
        else { throw OpenSSHImportError(String(localized: "The key file is too large or is not UTF-8 text.")) }
        return text
    }

    private static func derivePublicKey(privateKey: String, passphrase: String) throws -> String {
        #if os(macOS)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tamio-import-key-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = directory.appendingPathComponent("key")
            let helper = directory.appendingPathComponent("askpass")
            let output = directory.appendingPathComponent("public")
            try Data(privateKey.utf8).write(to: key, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
            try Data("#!/bin/sh\nprintf '%s\\n' \"$TAMIO_IMPORT_PASSPHRASE\"\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw OpenSSHImportError(String(localized: "The private key could not be validated."))
            }
            let outputHandle = try FileHandle(forWritingTo: output)
            defer { try? outputHandle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-y", "-f", key.path]
            process.environment = ["PATH": "/usr/bin:/bin", "DISPLAY": "tamio-import", "SSH_ASKPASS": helper.path,
                                   "SSH_ASKPASS_REQUIRE": "force", "TAMIO_IMPORT_PASSPHRASE": passphrase]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputHandle
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try Task.checkCancellation()
                throw OpenSSHImportError(String(localized: "Private-key validation was cancelled or timed out."))
            }
            process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw OpenSSHImportError(String(localized: "The private key could not be opened. Check its format and passphrase."))
            }
            return try readRegularFile(output.path, limit: 64 * 1024).trimmingCharacters(in: .whitespacesAndNewlines)
        #else
            throw OpenSSHImportError(String(localized: "Importing OpenSSH private keys is available on macOS."))
        #endif
    }
}
