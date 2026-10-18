//
//  AgentRunner.swift
//  TamioModule
//
//  Runs an agent's command on servers, several at a time, over Tamio's own
//  connections and credentials: the agent never sees them. Each server's
//  exit code is read from a marker the wrapped command prints last.
//

import Foundation
import NSRemoteShell

public struct AgentRunResult: Codable, Sendable {
    public var host: String
    public var hostID: String
    public var exitCode: Int?
    public var output: String
    /// The output was longer than the cap; its end is kept.
    public var truncated: Bool
    /// Why there is no exit code: could not connect, sign in, or timed out.
    public var error: String?
    public var seconds: Double
}

enum AgentRunner {
    static let outputCap = 1_000_000
    static let marker = "__TAMIO_EXIT__"

    /// `sh -c` with the command quoted; sudo -n never waits for a password.
    static func wrap(_ command: String, sudo: Bool) -> String {
        let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let run = sudo ? "sudo -n sh -c \(quoted)" : "sh -c \(quoted)"
        return "\(run) 2>&1; printf '\\n\(marker)%d\\n' $?"
    }

    /// Splits the marker off the output.
    static func parse(_ raw: String) -> (output: String, exitCode: Int?) {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let range = text.range(of: marker, options: .backwards) else { return (text, nil) }
        let code = Int(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines))
        var output = String(text[..<range.lowerBound])
        if output.hasSuffix("\n") { output.removeLast() }
        return (output, code)
    }

    @MainActor
    static func run(command: String, on machines: [RDMachine], sudo: Bool, timeout: Double, concurrency: Int) async -> [AgentRunResult] {
        let store = TamioStore.shared
        let jobs = machines.map { machine in
            (machine: machine, identity: store.associatedIdentity(for: machine), timeout: store.timeoutNumber)
        }
        let script = wrap(command, sudo: sudo)
        let limit = max(1, min(concurrency, 32))
        return await withTaskGroup(of: (Int, AgentRunResult).self) { group in
            var results = [AgentRunResult?](repeating: nil, count: jobs.count)
            var next = 0
            func start(_ index: Int) {
                let job = jobs[index]
                group.addTask {
                    (index, await runOne(script: script, machine: job.machine, identity: job.identity, connectTimeout: job.timeout, timeout: timeout))
                }
            }
            while next < min(limit, jobs.count) { start(next); next += 1 }
            for await (index, result) in group {
                results[index] = result
                if next < jobs.count { start(next); next += 1 }
            }
            return results.compactMap { $0 }
        }
    }

    static func runOne(script: String, machine: RDMachine, identity: RDIdentity?, connectTimeout: NSNumber, timeout: Double) async -> AgentRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                var result = AgentRunResult(host: machine.name, hostID: machine.id.uuidString, exitCode: nil, output: "", truncated: false, error: nil, seconds: 0)
                let shell = NSRemoteShell.configured(for: machine, timeout: connectTimeout)
                defer {
                    shell.requestDisconnectAndWait()
                    shell.destroyPermanently()
                }
                guard let identity else {
                    result.error = "This server has no password or key in Tamio."
                    return continuation.resume(returning: result)
                }
                shell.requestConnectAndWait()
                guard shell.isConnected else {
                    result.error = shell.hostKeyRefusal ?? shell.getLastError() ?? "Could not reach \(machine.remoteAddress):\(machine.remotePort)."
                    return continuation.resume(returning: result)
                }
                identity.callAuthenticationWith(remote: shell, username: machine.loginUsername(with: identity))
                guard shell.isAuthenticated else {
                    result.error = "Could not sign in as \(machine.loginUsername(with: identity))."
                    return continuation.resume(returning: result)
                }
                let lock = NSLock()
                nonisolated(unsafe) var output = ""
                nonisolated(unsafe) var truncated = false
                let deadline = started.addingTimeInterval(timeout)
                shell.beginExecute(
                    withCommand: script,
                    withTimeout: NSNumber(value: timeout),
                    withOnCreate: {},
                    withOutput: { chunk in
                        lock.lock()
                        output += chunk
                        if output.utf8.count > outputCap * 2 {
                            output = String(output.suffix(outputCap))
                            truncated = true
                        }
                        lock.unlock()
                    },
                    withContinuationHandler: { Date() < deadline }
                )
                lock.lock()
                let raw = output
                lock.unlock()
                let parsed = parse(raw)
                result.exitCode = parsed.exitCode
                result.truncated = truncated || parsed.output.utf8.count > outputCap
                result.output = parsed.output.utf8.count > outputCap ? String(parsed.output.suffix(outputCap)) : parsed.output
                if parsed.exitCode == nil {
                    result.error = Date() >= deadline ? "Timed out after \(Int(timeout)) s." : "The command ended without an exit code."
                }
                result.seconds = Date().timeIntervalSince(started)
                continuation.resume(returning: result)
            }
        }
    }
}
