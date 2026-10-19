#if os(macOS)
import Foundation
@testable import TamioModule
import XCTest

final class OpenSSHConfigResolverTests: XCTestCase {
    func testNativeDifferentialResolutionPreservesIncludesAndFirstValueWins() async throws {
        try requireSSH()
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let includes = try fixture.directory("includes")
        try fixture.write("includes/10-first.conf", """
        Host alpha beta
            Port 2201
            IdentityFile "~/keys/first key"
        Host otherwise
            User wrong
        """)
        try fixture.write("includes/20-second.conf", """
        Host alpha
            Port 2202
            IdentityFile ~/keys/second
        Host nested
            HostName nested.example
        """)
        let inactive = try fixture.write("inactive", "Host alpha\n  User must-not-leak\n")
        let source = try fixture.write("config", """
        Host alpha beta
            User deploy
            HostName destination.example
            Include "\(includes.path)/*.conf"
            ServerAliveInterval 19
        Host not-selected
            Include "\(inactive.path)"
        Host alpha
            ProxyJump jump-one,jump-two
        Match originalhost beta
            HostName should-not-win.example
            Compression yes
        Host *
            User fallback
            Port 22
            IdentityFile ~/keys/default
        """)
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        let results = try await OpenSSHConfigResolver.resolve(scan: scan, trusted: false)
        XCTAssertEqual(results.count, scan.hosts.count)
        for resolved in results {
            XCTAssertNil(resolved.error, resolved.candidate.alias)
            let native = try nativeOptions(source, resolved.candidate.alias)
            XCTAssertEqual(resolved.options, native, resolved.candidate.alias)
        }
        let alpha = try XCTUnwrap(results.first(where: { $0.candidate.alias == "alpha" }))
        XCTAssertEqual(alpha.options["user"], ["deploy"])
        XCTAssertEqual(alpha.options["port"], ["2201"])
        XCTAssertEqual(alpha.options["identityfile"], ["~/keys/first key", "~/keys/second", "~/keys/default"])
    }

    func testNativeDifferentialRelativeIncludeUsesUserSSHDirectory() async throws {
        try requireSSH()
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let homeSSH = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        var isDirectory: ObjCBool = false
        try XCTSkipUnless(FileManager.default.fileExists(atPath: homeSSH.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                          "A user .ssh directory is needed for relative Include semantics")
        let name = "tamio-import-test-\(UUID().uuidString)"
        let child = homeSSH.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: child) }
        try "Host relative\n  User relative-user\n  Port 2299\n".write(to: child, atomically: false, encoding: .utf8)
        let source = try fixture.write("config", "Include \(name)\nHost relative\n  HostName relative.example\n")
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        let resolved = try await OpenSSHConfigResolver.resolve(scan: scan, trusted: false)
        XCTAssertEqual(try XCTUnwrap(resolved.first).options, try nativeOptions(source, "relative"))
        XCTAssertEqual(scan.hosts.first?.source.path, child.path)
    }

    func testNativeDifferentialFinalPassAndQuotedEqualsSyntax() async throws {
        try requireSSH()
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let source = try fixture.write("config", """
        Host = "quoted-host"
            HostName = final.example
            User = first
            Port=2222
        Match final host final.example
            Compression yes
        Host *
            ServerAliveInterval 31
        """)
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        let results = try await OpenSSHConfigResolver.resolve(scan: scan, trusted: false)
        XCTAssertEqual(results.first?.options, try nativeOptions(source, "quoted-host"))
        XCTAssertFalse(scan.requiresTrust)
    }

    func testTrustGateNeverExecutesBeforeApproval() async throws {
        try requireSSH()
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("executed")
        let source = try fixture.write("config", """
        Host trusted
            HostName example.invalid
        Match exec "touch '\(marker.path)'"
            User approved
        """)
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        XCTAssertTrue(scan.requiresTrust)
        do {
            _ = try await OpenSSHConfigResolver.resolve(scan: scan, trusted: false)
            XCTFail("Resolution ran without trust")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let resolved = try await OpenSSHConfigResolver.resolve(scan: scan, trusted: true)
        XCTAssertNil(resolved.first?.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(resolved.first?.options["user"], ["approved"])
    }

    func testSourceMutationCannotBypassTrustGate() async throws {
        try requireSSH()
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("executed")
        let child = try fixture.write("child", "Host stable\n  User frozen\n")
        let source = try fixture.write("config", "Include \"\(child.path)\"\nHost stable\n  HostName frozen.example\n")
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        try fixture.write("child", "Match exec \"touch '\(marker.path)'\"\n  User changed\n")
        try fixture.write("config", "Match exec \"touch '\(marker.path)'\"\nHost stable\n  HostName changed.example\n")
        let results = try await OpenSSHConfigResolver.resolve(scan: scan, trusted: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(results.first?.options["user"], ["frozen"])
        XCTAssertEqual(results.first?.options["hostname"], ["frozen.example"])
    }

    func testOutputLimitAndInvalidSettingsBecomePerHostErrors() async throws {
        try requireSSH()
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let source = try fixture.write("config", "Host bounded\n  HostName example.invalid\n")
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        let bounded = try await OpenSSHConfigResolver.resolve(scan: scan, trusted: false, limits: .init(outputBytes: 128))
        XCTAssertNotNil(bounded.first?.error)
        XCTAssertTrue(bounded.first?.options.isEmpty == true)
        try fixture.write("config", "Host invalid\n  InvalidSetting never-display-this-secret\n")
        let invalid = try await OpenSSHConfigResolver.resolve(scan: OpenSSHConfigScanner.scan(path: source.path), trusted: false)
        let message = try XCTUnwrap(invalid.first?.error)
        XCTAssertFalse(message.contains("never-display-this-secret"))
    }

    func testTrustedExecTimeoutKillsCommandGroup() async throws {
        try requireSSH()
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("must-not-appear")
        let source = try fixture.write("config", "Host slow\nMatch exec \"sleep 1; touch '\(marker.path)'\"\n  User late\n")
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        let results = try await OpenSSHConfigResolver.resolve(scan: scan, trusted: true, limits: .init(hostSeconds: 0.1))
        XCTAssertNotNil(results.first?.error)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testCancellationKillsStartedExecAndDoesNotReturnPartialResults() async throws {
        try requireSSH()
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let started = fixture.root.appendingPathComponent("started")
        let finished = fixture.root.appendingPathComponent("must-not-finish")
        let source = try fixture.write("config", "Host cancellable\nMatch exec \"touch '\(started.path)'; sleep 1; touch '\(finished.path)'\"\n  User late\n")
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        let task = Task { try await OpenSSHConfigResolver.resolve(scan: scan, trusted: true) }
        for _ in 0 ..< 100 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled resolution returned results")
        } catch is CancellationError {
        }
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finished.path))
    }

    func testParserKeepsCommandsAndRepeatedOptions() throws {
        let values = try OpenSSHConfigResolver.parse("hostname example\nuser deploy\nport 22\nidentityfile first key\nidentityfile second\nproxycommand nc -X connect -x proxy:80 %h %p\n")
        XCTAssertEqual(values["identityfile"], ["first key", "second"])
        XCTAssertEqual(values["proxycommand"], ["nc -X connect -x proxy:80 %h %p"])
        XCTAssertThrowsError(try OpenSSHConfigResolver.parse("hostname example\nuser deploy\nport 0\n"))
    }

    private func requireSSH() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh"), "System OpenSSH is required")
    }

    private func nativeOptions(_ config: URL, _ alias: String) throws -> [String: [String]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", config.path, "--", alias]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try OpenSSHConfigResolver.parse(String(decoding: data, as: UTF8.self))
    }
}
#endif
