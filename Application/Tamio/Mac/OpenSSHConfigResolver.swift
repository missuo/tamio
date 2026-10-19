#if os(macOS)
import Darwin
import Foundation
import TamioModule

/// Native resolution stays in the Mac adapter. No server connection is made by ssh -G.
enum OpenSSHConfigResolver {
    struct Limits: Sendable {
        var hostSeconds: TimeInterval = 5
        var totalSeconds: TimeInterval = 60
        var outputBytes = 1024 * 1024
        var totalOutputBytes = 8 * 1024 * 1024
    }

    static func resolve(scan: OpenSSHScan, trusted: Bool) async throws -> [OpenSSHResolvedHost] {
        try await resolve(scan: scan, trusted: trusted, limits: Limits())
    }

    static func resolve(scan: OpenSSHScan, trusted: Bool, limits: Limits) async throws -> [OpenSSHResolvedHost] {
        try Task.checkCancellation()
        guard trusted || !scan.requiresTrust else {
            throw OpenSSHConfigError(String(localized: "This SSH configuration can execute local commands. Explicit trust is required before resolving it."))
        }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try cancellation.check()
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tamio-ssh-\(UUID().uuidString)", isDirectory: true)
                        let config = try scan.materializeSnapshot(in: directory)
                        defer { try? FileManager.default.removeItem(at: directory) }
                        let deadline = ProcessInfo.processInfo.systemUptime + limits.totalSeconds
                        var results: [OpenSSHResolvedHost] = []
                        var totalOutputBytes = 0
                        for candidate in scan.hosts {
                            try cancellation.check()
                            let remaining = deadline - ProcessInfo.processInfo.systemUptime
                            guard remaining > 0 else {
                                throw OpenSSHConfigError(String(localized: "Resolving the SSH configuration exceeded the 60-second time limit."))
                            }
                            do {
                                let text = try run(config: config.path, alias: candidate.alias,
                                                   seconds: min(limits.hostSeconds, remaining),
                                                   outputBytes: limits.outputBytes, cancellation: cancellation)
                                totalOutputBytes += text.utf8.count
                                guard totalOutputBytes <= limits.totalOutputBytes else {
                                    throw OpenSSHConfigError(String(localized: "The resolved SSH configuration exceeds the 8 MB output limit."))
                                }
                                results.append(OpenSSHResolvedHost(candidate: candidate, options: try parse(text)))
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                results.append(OpenSSHResolvedHost(candidate: candidate, options: [:], error: error.localizedDescription))
                            }
                            guard totalOutputBytes <= limits.totalOutputBytes else {
                                throw OpenSSHConfigError(String(localized: "The resolved SSH configuration exceeds the 8 MB output limit."))
                            }
                        }
                        try cancellation.check()
                        continuation.resume(returning: results)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Split only once: commands and paths may contain spaces, and repeated keys are meaningful.
    static func parse(_ text: String) throws -> [String: [String]] {
        var options: [String: [String]] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let split = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                throw OpenSSHConfigError(String(localized: "OpenSSH returned an invalid configuration result."))
            }
            let key = String(line[..<split]).lowercased()
            let value = String(line[split...].drop(while: { $0 == " " || $0 == "\t" }))
            options[key, default: []].append(value)
        }
        guard options["hostname"]?.first?.isEmpty == false, options["user"]?.first?.isEmpty == false,
              let port = options["port"]?.first, let number = Int(port), (1 ... 65535).contains(number)
        else { throw OpenSSHConfigError(String(localized: "OpenSSH did not return a usable host, username, and port.")) }
        return options
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock()
            let value = cancelled
            lock.unlock()
            if value { throw CancellationError() }
        }
    }

    private static func run(config: String, alias: String, seconds: TimeInterval, outputBytes: Int, cancellation: Cancellation) throws -> String {
        try cancellation.check()
        var stdout = [Int32](repeating: -1, count: 2)
        var stderr = [Int32](repeating: -1, count: 2)
        guard pipe(&stdout) == 0 else { throw launchError() }
        defer { for fd in stdout where fd >= 0 { close(fd) } }
        guard pipe(&stderr) == 0 else { throw launchError() }
        defer { for fd in stderr where fd >= 0 { close(fd) } }
        for fd in stdout + stderr {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw launchError() }
        }
        guard fcntl(stdout[0], F_SETFL, O_NONBLOCK) == 0,
              fcntl(stderr[0], F_SETFL, O_NONBLOCK) == 0 else { throw launchError() }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw launchError() }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw launchError() }
        defer { posix_spawnattr_destroy(&attributes) }
        // A separate process group lets timeout/cancellation stop Match exec children too.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderr[1], STDERR_FILENO) == 0
        else { throw launchError() }
        let arguments = ["/usr/bin/ssh", "-G", "-F", config, "--", alias]
        // Keep the user's environment for documented Match exec semantics after trust.
        // ssh -G never uses askpass; stdin is always closed to interactive input.
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let launched = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, "/usr/bin/ssh", &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard launched == 0 else { throw launchError() }
        close(stdout[1]); stdout[1] = -1
        close(stderr[1]); stderr[1] = -1
        var reaped = false
        defer {
            // Kill remaining group members even if ssh exited while an exec child retained pipes.
            kill(-pid, SIGKILL)
            if !reaped {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var output = Data()
        var errorBytes = 0
        var outputEnded = false
        var errorEnded = false
        var status: Int32 = 0
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw OpenSSHConfigError(String(localized: "OpenSSH took too long to resolve this host. Any resolution commands were stopped."))
            }
            for (fd, isOutput) in [(stdout[0], true), (stderr[0], false)] {
                if isOutput ? outputEnded : errorEnded { continue }
                // Bounded reads give cancellation/deadline checks a turn even under a write flood.
                for _ in 0 ..< 8 {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count == 0 {
                        if isOutput { outputEnded = true } else { errorEnded = true }
                        break
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        throw OpenSSHConfigError(String(localized: "Could not read the OpenSSH configuration result."))
                    }
                    if isOutput { output.append(contentsOf: buffer.prefix(count)) } else { errorBytes += count }
                    guard output.count + errorBytes <= outputBytes else {
                        throw OpenSSHConfigError(String(localized: "OpenSSH produced too much output while resolving this host."))
                    }
                }
            }
            if !reaped {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { reaped = true }
                if result < 0, errno != EINTR { throw launchError() }
            }
            if reaped, outputEnded, errorEnded { break }
            var descriptors = [pollfd(fd: stdout[0], events: Int16(POLLIN), revents: 0),
                               pollfd(fd: stderr[0], events: Int16(POLLIN), revents: 0)]
            if outputEnded { descriptors[0].fd = -1 }
            if errorEnded { descriptors[1].fd = -1 }
            _ = poll(&descriptors, nfds_t(descriptors.count), 20)
        }
        // Never surface stderr: Match exec output and parser errors can contain secrets.
        guard status == 0 else {
            throw OpenSSHConfigError(String(localized: "OpenSSH could not resolve this host. Check the configuration for invalid or unsupported settings."))
        }
        guard let text = String(data: output, encoding: .utf8) else {
            throw OpenSSHConfigError(String(localized: "OpenSSH returned a configuration that is not UTF-8 text."))
        }
        return text
    }

    private static func launchError() -> OpenSSHConfigError {
        OpenSSHConfigError(String(localized: "Could not start the system OpenSSH configuration resolver."))
    }
}
#endif
