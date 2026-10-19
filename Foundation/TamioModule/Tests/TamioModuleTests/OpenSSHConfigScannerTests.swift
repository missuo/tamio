import Darwin
import Foundation
@testable import TamioModule
import XCTest

final class OpenSSHConfigScannerTests: XCTestCase {
    func testHarmlessDefaultsDoNotRequireReviewAndKeywordsMayContainDigits() throws {
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let child = try fixture.write("with space.conf", "Host plain\n  User deploy\n")
        let escaped = child.path.replacingOccurrences(of: " ", with: "\\ ")
        let source = try fixture.write("config", "Include \(escaped)\nHost *\n  PKCS11Provider none\n  IdentityFile2 ~/.ssh/id_rsa\n")
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        XCTAssertEqual(scan.hosts.map(\.alias), ["plain"])
        XCTAssertTrue(scan.warnings.isEmpty)
        XCTAssertTrue(scan.directives.contains("pkcs11provider"))
        XCTAssertTrue(scan.directives.contains("identityfile2"))
    }

    func testAliasesIncludesOrderAndSourceLocations() throws {
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let includes = try fixture.directory("included files")
        try fixture.write("included files/20-second.conf", "Host beta alpha\n  User second\n")
        try fixture.write("included files/10-first.conf", "Host gamma\n  User first\n")
        let source = try fixture.write("config", """
        # A comment with Match exec is not executable.
        Host alpha Alias-A !excluded *.example ?host [abc]
            HostName alpha.example
        Include "\(includes.path)/*.conf"
        HOST ALPHA beta
            Port 2222
        Host -oBad
        """)
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        XCTAssertEqual(scan.hosts.map(\.alias), ["alpha", "Alias-A", "gamma", "beta"])
        XCTAssertEqual(scan.hosts[0].source, OpenSSHSourceLocation(path: source.path, line: 2))
        XCTAssertEqual(scan.hosts[2].source.path, includes.appendingPathComponent("10-first.conf").path)
        XCTAssertFalse(scan.requiresTrust)
        XCTAssertEqual(scan.directives, ["host", "hostname", "include", "user", "port"])
        XCTAssertFalse(scan.warnings.isEmpty)
    }

    func testExecInInactiveRecursiveIncludeRequiresTrustWithoutExecution() throws {
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("executed")
        let nested = try fixture.write("nested", "Match !exec \"touch '\(marker.path)'\"\n  User dangerous\n")
        let child = try fixture.write("child", "Include \"\(nested.path)\"\n")
        let source = try fixture.write("config", "Host safe\n  HostName safe.example\nHost never-match-*\n  Include \"\(child.path)\"\n")
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        XCTAssertTrue(scan.requiresTrust)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUninspectableIncludesAndSyntaxFailClosed() throws {
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        for text in ["Include %h.conf", "Include ${HOME}/.ssh/config", "Include \"unterminated", "Include", "Host alpha\u{0}beta", "Match exec \\\n"] {
            let source = try fixture.write("config", text)
            XCTAssertThrowsError(try OpenSSHConfigScanner.scan(path: source.path), text)
        }
    }

    func testCyclesHardlinksAndSpecialFilesAreRejected() throws {
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let config = fixture.root.appendingPathComponent("config")
        try fixture.write("config", "Include \"\(config.path)\"\n")
        XCTAssertThrowsError(try OpenSSHConfigScanner.scan(path: config.path))
        let hardlink = fixture.root.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: config, to: hardlink)
        try fixture.write("config", "Include \"\(hardlink.path)\"\n")
        XCTAssertThrowsError(try OpenSSHConfigScanner.scan(path: config.path))
        let fifo = fixture.root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try OpenSSHConfigScanner.scan(path: fifo.path))
        XCTAssertThrowsError(try OpenSSHConfigScanner.scan(path: fixture.root.path))
    }

    func testSymlinksAreReadAndFrozenNotReopened() throws {
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let child = try fixture.write("child", "Host child\n  User before\n")
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
        let source = try fixture.write("config", "Include \"\(link.path)\"\n")
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        try FileManager.default.removeItem(at: link)
        try fixture.write("link", "Match exec \"false\"\n")
        try fixture.write("config", "Match exec \"false\"\n")
        let directory = fixture.root.appendingPathComponent("snapshot")
        let snapshot = try scan.materializeSnapshot(in: directory)
        let root = try String(contentsOf: snapshot, encoding: .utf8)
        let frozenChild = try String(contentsOf: directory.appendingPathComponent("1.conf"), encoding: .utf8)
        XCTAssertFalse(root.contains(link.path))
        XCTAssertTrue(frozenChild.contains("User before"))
        XCTAssertFalse(frozenChild.contains("Match exec"))
        XCTAssertFalse(scan.requiresTrust)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
    }

    func testMissingIncludesAreFrozenAsMissing() throws {
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing-*.conf")
        let source = try fixture.write("config", "Include \"\(missing.path)\"\nHost only\n")
        let scan = try OpenSSHConfigScanner.scan(path: source.path)
        try fixture.write("missing-new.conf", "Match exec \"false\"\n")
        let snapshot = try scan.materializeSnapshot(in: fixture.root.appendingPathComponent("snapshot"))
        XCTAssertFalse(try String(contentsOf: snapshot, encoding: .utf8).contains(missing.path))
        XCTAssertEqual(scan.hosts.map(\.alias), ["only"])
        XCTAssertFalse(scan.requiresTrust)
    }

    func testBoundsRejectLargeFilesAliasFloodsAndDeepIncludes() throws {
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let large = try fixture.write("large", String(repeating: "# comment\n", count: 120000))
        XCTAssertThrowsError(try OpenSSHConfigScanner.scan(path: large.path))
        let aliases = try fixture.write("aliases", (0 ... 512).map { "Host alias\($0)\n" }.joined())
        XCTAssertThrowsError(try OpenSSHConfigScanner.scan(path: aliases.path))
        for index in 0 ... 18 {
            let next = fixture.root.appendingPathComponent("depth-\(index + 1)").path
            try fixture.write("depth-\(index)", index == 18 ? "Host last\n" : "Include \"\(next)\"\n")
        }
        XCTAssertThrowsError(try OpenSSHConfigScanner.scan(path: fixture.root.appendingPathComponent("depth-0").path))
    }

    func testSyntheticScanCannotBeResolvedAsInspectedSnapshot() throws {
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let scan = OpenSSHScan(sourcePath: "/not-scanned", hosts: [])
        XCTAssertThrowsError(try scan.materializeSnapshot(in: fixture.root.appendingPathComponent("snapshot")))
    }

    func testCancelledScannerStopsBeforeReading() async throws {
        let fixture = try SSHConfigFixture()
        defer { fixture.remove() }
        let source = try fixture.write("config", "Host example\n")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try OpenSSHConfigScanner.scan(path: source.path)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled scan returned a result")
        } catch is CancellationError {
        }
    }
}

struct SSHConfigFixture: Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tamio-ssh-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    @discardableResult
    func write(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
