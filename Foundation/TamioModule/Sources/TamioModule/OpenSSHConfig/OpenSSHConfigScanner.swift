import Darwin
import Foundation

public struct OpenSSHSourceLocation: Sendable, Equatable {
    public let path: String
    public let line: Int

    public init(path: String, line: Int) {
        self.path = path
        self.line = line
    }
}

public struct OpenSSHHostCandidate: Identifiable, Sendable, Equatable {
    public var id: String { alias }
    public let alias: String
    public let source: OpenSSHSourceLocation

    public init(alias: String, source: OpenSSHSourceLocation) {
        self.alias = alias
        self.source = source
    }
}

public struct OpenSSHResolvedHost: Sendable {
    public let candidate: OpenSSHHostCandidate
    public let options: [String: [String]]
    public let error: String?

    public init(candidate: OpenSSHHostCandidate, options: [String: [String]], error: String? = nil) {
        self.candidate = candidate
        self.options = options
        self.error = error
    }
}

public struct OpenSSHScan: Sendable {
    public let sourcePath: String
    public let hosts: [OpenSSHHostCandidate]
    public let warnings: [String]
    public let requiresTrust: Bool
    public let directives: Set<String>
    fileprivate let snapshot: [OpenSSHSnapshotFile]

    /// Data-only initializer for planning saved or synthetic resolution results.
    /// Only the scanner can create a snapshot that is eligible for native resolution.
    public init(sourcePath: String, hosts: [OpenSSHHostCandidate], warnings: [String] = [], requiresTrust: Bool = false, directives: Set<String> = []) {
        self.sourcePath = sourcePath
        self.hosts = hosts
        self.warnings = warnings
        self.requiresTrust = requiresTrust
        self.directives = directives
        snapshot = []
    }

    fileprivate init(sourcePath: String, hosts: [OpenSSHHostCandidate], warnings: [String], requiresTrust: Bool, directives: Set<String>, snapshot: [OpenSSHSnapshotFile]) {
        self.sourcePath = sourcePath
        self.hosts = hosts
        self.warnings = warnings
        self.requiresTrust = requiresTrust
        self.directives = directives
        self.snapshot = snapshot
    }

    /// Writes only bytes inspected by the scanner, never reopening original paths.
    /// The caller owns this new private directory and must remove it after use.
    public func materializeSnapshot(in directory: URL) throws -> URL {
        guard !snapshot.isEmpty else {
            throw OpenSSHConfigError(String(localized: "Scan the SSH configuration again before resolving it."))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for (index, file) in snapshot.enumerated() {
                try Task.checkCancellation()
                var text = ""
                for line in file.lines {
                    switch line {
                    case let .text(value):
                        text += value + "\n"
                    case let .include(children):
                        // Keep the Include boundary: OpenSSH restores the caller's match state
                        // after parsing an included file. Flattening changes that behavior.
                        if children.isEmpty {
                            text += "# Include had no matches when scanned.\n"
                        } else {
                            for child in children {
                                let path = directory.appendingPathComponent("\(child).conf").path
                                guard !path.contains("\""), !path.contains("\\"), !path.contains("\n"), !path.contains("\r"), !path.contains("%"), !path.contains("$") else {
                                    throw OpenSSHConfigError(String(localized: "The temporary folder cannot safely hold an SSH configuration snapshot."))
                                }
                                text += "Include \"\(path)\"\n"
                            }
                        }
                    }
                }
                let destination = directory.appendingPathComponent("\(index).conf")
                guard FileManager.default.createFile(atPath: destination.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o400]) else {
                    throw OpenSSHConfigError(String(localized: "Could not create the private SSH configuration snapshot."))
                }
            }
            return directory.appendingPathComponent("0.conf")
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

public struct OpenSSHConfigError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private struct OpenSSHSnapshotFile: Sendable {
    enum Line: Sendable {
        case text(String)
        case include([Int])
    }

    var lines: [Line] = []
}

public enum OpenSSHConfigScanner {
    public static func scan(path: String) throws -> OpenSSHScan {
        var scanner = Scanner()
        let expanded = (path as NSString).expandingTildeInPath
        let source = URL(fileURLWithPath: expanded).standardizedFileURL.path
        _ = try scanner.visit(source, depth: 0)
        return OpenSSHScan(sourcePath: source, hosts: scanner.hosts, warnings: scanner.warnings,
                           requiresTrust: scanner.requiresTrust, directives: scanner.directives,
                           snapshot: scanner.files)
    }

    private struct Scanner {
        static let maximumBytes = 4 * 1024 * 1024
        static let maximumFileBytes = 1024 * 1024
        static let maximumFiles = 128
        static let maximumDepth = 16
        static let maximumHosts = 512
        static let maximumDirectoryEntries = 16384

        var hosts: [OpenSSHHostCandidate] = []
        var warnings: [String] = []
        var requiresTrust = false
        var directives: Set<String> = []
        var files: [OpenSSHSnapshotFile] = []
        var aliases: Set<String> = []
        var activeFiles: Set<String> = []
        var bytesRead = 0
        var directoryEntries = 0

        mutating func visit(_ path: String, depth: Int) throws -> Int {
            try Task.checkCancellation()
            guard depth <= Self.maximumDepth, files.count < Self.maximumFiles else {
                throw OpenSSHConfigError(String(localized: "The SSH configuration includes too many files or too many nested Includes."))
            }
            let (text, identity) = try readRegularFile(path)
            guard activeFiles.insert(identity).inserted else {
                throw OpenSSHConfigError(String(localized: "The SSH configuration contains an Include cycle at \(path)."))
            }
            defer { activeFiles.remove(identity) }
            let index = files.count
            files.append(OpenSSHSnapshotFile())
            var lines: [OpenSSHSnapshotFile.Line] = []
            for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
                try Task.checkCancellation()
                let location = OpenSSHSourceLocation(path: path, line: offset + 1)
                guard rawLine.utf8.count <= 32768 else { throw syntaxError(location) }
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                guard !line.utf8.contains(where: { $0 < 32 && $0 != 9 }) else { throw syntaxError(location) }
                let (keyword, remainder) = try directive(line, location: location)
                guard let keyword else {
                    lines.append(.text(line))
                    continue
                }
                directives.insert(keyword)
                switch keyword {
                case "include":
                    let patterns = try arguments(remainder, location: location)
                    guard !patterns.isEmpty else { throw syntaxError(location) }
                    var children: [Int] = []
                    for pattern in patterns {
                        let paths = try includePaths(pattern, location: location)
                        for child in paths {
                            children.append(try visit(child, depth: depth + 1))
                        }
                    }
                    lines.append(.include(children))
                case "host":
                    let patterns = try arguments(remainder, location: location)
                    guard !patterns.isEmpty else { throw syntaxError(location) }
                    for alias in patterns {
                        if alias.hasPrefix("!") || alias.contains("*") || alias.contains("?") || alias.contains("[") || alias.contains("]") || alias.contains(",") {
                            continue
                        }
                        guard !alias.isEmpty, !alias.hasPrefix("-"), alias.utf8.count <= 255,
                              alias.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-:".unicodeScalars.contains($0) })
                        else {
                            warn(String(localized: "A Host alias at \(path):\(offset + 1) cannot safely be imported."))
                            continue
                        }
                        if aliases.insert(alias.lowercased()).inserted {
                            guard hosts.count < Self.maximumHosts else {
                                throw OpenSSHConfigError(String(localized: "The SSH configuration contains more than 512 server aliases."))
                            }
                            hosts.append(OpenSSHHostCandidate(alias: alias, source: location))
                        }
                    }
                    lines.append(.text(line))
                case "match":
                    let tokens = try arguments(remainder, location: location)
                    guard !tokens.isEmpty else { throw syntaxError(location) }
                    // Fail conservatively even if the word is an argument rather than a condition.
                    // The untouched Match expression is still interpreted only by OpenSSH.
                    if tokens.contains(where: { $0.lowercased().contains("exec") }) {
                        requiresTrust = true
                        warn(String(localized: "Match exec can run local commands while OpenSSH resolves this configuration. Resolve only if you trust every included file."))
                    }
                    warn(String(localized: "Match conditions can depend on this Mac, its network, and the time of import. Review the resolved settings."))
                    lines.append(.text(line))
                default:
                    // Ordinary settings are preserved byte-for-byte; native ssh validates them.
                    lines.append(.text(line))
                }
            }
            files[index].lines = lines
            return index
        }

        mutating func readRegularFile(_ path: String) throws -> (String, String) {
            // O_NONBLOCK prevents FIFOs and devices from blocking before fstat can reject them.
            let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw OpenSSHConfigError(String(localized: "Could not read SSH configuration file \(path).")) }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                throw OpenSSHConfigError(String(localized: "SSH configuration path \(path) is not a regular file."))
            }
            guard info.st_size <= Self.maximumFileBytes, info.st_size >= 0 else {
                throw OpenSSHConfigError(String(localized: "SSH configuration file \(path) is larger than 1 MB."))
            }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw OpenSSHConfigError(String(localized: "Could not read SSH configuration file \(path)."))
                }
                bytesRead += count
                guard bytes.count + count <= Self.maximumFileBytes, bytesRead <= Self.maximumBytes else {
                    throw OpenSSHConfigError(String(localized: "The SSH configuration exceeds the 4 MB import limit or the 1 MB per-file limit."))
                }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
                throw OpenSSHConfigError(String(localized: "SSH configuration file \(path) is not valid UTF-8 text."))
            }
            return (text, "\(info.st_dev):\(info.st_ino)")
        }

        mutating func includePaths(_ pattern: String, location: OpenSSHSourceLocation) throws -> [String] {
            // Host-dependent tokens cannot be expanded before native evaluation, so never leave
            // those Includes pointing at uninspected live files, even after trust approval.
            guard !pattern.contains("%"), !pattern.contains("$"), !pattern.contains("\\"), !pattern.contains("\r"), !pattern.contains("\n") else {
                throw OpenSSHConfigError(String(localized: "An Include at \(location.path):\(location.line) uses expansion that cannot be inspected safely."))
            }
            var absolute = pattern
            if absolute.hasPrefix("~") {
                absolute = (absolute as NSString).expandingTildeInPath
                guard !absolute.hasPrefix("~") else { throw syntaxError(location) }
            } else if !absolute.hasPrefix("/") {
                // OpenSSH resolves user-config Includes against ~/.ssh, not the parent file.
                absolute = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh").appendingPathComponent(absolute).path
            }
            let components = absolute.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var paths = ["/"]
            for component in components {
                try Task.checkCancellation()
                var next: [String] = []
                for parent in paths {
                    if component.contains("*") || component.contains("?") || component.contains("[") {
                        let directory = opendir(parent)
                        guard let directory else {
                            if errno == ENOENT || errno == ENOTDIR { continue }
                            throw OpenSSHConfigError(String(localized: "Could not inspect Include directory \(parent)."))
                        }
                        defer { closedir(directory) }
                        errno = 0
                        while let entry = readdir(directory) {
                            try Task.checkCancellation()
                            directoryEntries += 1
                            guard directoryEntries <= Self.maximumDirectoryEntries else {
                                throw OpenSSHConfigError(String(localized: "The SSH Include patterns inspect too many directory entries."))
                            }
                            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                            }
                            if name != ".", name != "..", fnmatch(component, name, FNM_PERIOD) == 0 {
                                next.append((parent as NSString).appendingPathComponent(name))
                                guard next.count <= Self.maximumFiles else {
                                    throw OpenSSHConfigError(String(localized: "An SSH Include pattern matches too many files."))
                                }
                            }
                            errno = 0
                        }
                        guard errno == 0 else { throw OpenSSHConfigError(String(localized: "Could not inspect Include directory \(parent).")) }
                    } else {
                        let child = (parent as NSString).appendingPathComponent(component)
                        var info = stat()
                        if lstat(child, &info) == 0 {
                            next.append(child)
                        } else if errno != ENOENT, errno != ENOTDIR {
                            throw OpenSSHConfigError(String(localized: "Could not inspect SSH Include path \(child)."))
                        }
                    }
                }
                paths = next.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            }
            return paths
        }

        mutating func warn(_ message: String) {
            if !warnings.contains(message) { warnings.append(message) }
        }

        func syntaxError(_ location: OpenSSHSourceLocation) -> OpenSSHConfigError {
            OpenSSHConfigError(String(localized: "Cannot safely inspect SSH configuration syntax at \(location.path):\(location.line)."))
        }

        func directive(_ line: String, location: OpenSSHSourceLocation) throws -> (String?, Substring) {
            var rest = line.drop(while: { $0 == " " || $0 == "\t" })
            if rest.isEmpty || rest.first == "#" { return (nil, rest) }
            let keyword = rest.prefix(while: { $0 != " " && $0 != "\t" && $0 != "=" })
            guard !keyword.isEmpty, keyword.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }) else {
                throw syntaxError(location)
            }
            rest = rest.dropFirst(keyword.count).drop(while: { $0 == " " || $0 == "\t" })
            if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
            return (keyword.lowercased(), rest)
        }

        func arguments(_ text: Substring, location: OpenSSHSourceLocation) throws -> [String] {
            var tokens: [String] = []
            var token = ""
            var quote: Character?
            var started = false
            var cursor = text.startIndex
            while cursor < text.endIndex {
                let character = text[cursor]
                cursor = text.index(after: cursor)
                if character == "\\" {
                    guard cursor < text.endIndex else { throw syntaxError(location) }
                    let next = text[cursor]
                    // OpenSSH also accepts escaped spaces outside quotes.
                    // Reject other escapes rather than inspecting a different path.
                    guard next == "\\" || next == "\"" || next == "'" || (quote == nil && next == " ") else { throw syntaxError(location) }
                    token.append(next)
                    cursor = text.index(after: cursor)
                    started = true
                } else if let active = quote {
                    if character == active { quote = nil } else { token.append(character) }
                } else if character == "\"" || character == "'" {
                    quote = character
                    started = true
                } else if character == " " || character == "\t" {
                    if started { tokens.append(token); token = ""; started = false }
                } else if character == "#", !started {
                    break
                } else {
                    token.append(character)
                    started = true
                }
            }
            guard quote == nil else { throw syntaxError(location) }
            if started { tokens.append(token) }
            return tokens
        }
    }
}
