//
//  TerminalDirectoryTests.swift
//  TamioModuleTests
//
//  The folder a shell reports, read out of its output however the output is
//  cut into pieces.
//

@testable import TamioModule
import XCTest

final class TerminalDirectoryTests: XCTestCase {
    private func report(_ path: String, end: String = "\u{07}") -> String {
        "\u{1B}]7;file://web-01\(path)\(end)"
    }

    func testAReportIsRead() {
        var reader = WorkingDirectoryReader()
        XCTAssertEqual(reader.read("prompt " + report("/var/www") + "$ "), "/var/www")
        XCTAssertNil(reader.read("ls\r\nindex.html\r\n"))
    }

    func testTheLastReportOfAPieceWins() {
        var reader = WorkingDirectoryReader()
        XCTAssertEqual(reader.read(report("/a") + "x" + report("/b", end: "\u{1B}\\")), "/b")
    }

    func testAReportCutIntoPiecesIsRead() {
        let whole = "out " + report("/srv/app data") + "$ "
        for cut in whole.indices.dropFirst() {
            var reader = WorkingDirectoryReader()
            let first = reader.read(String(whole[..<cut]))
            let second = reader.read(String(whole[cut...]))
            XCTAssertEqual(first ?? second, "/srv/app data", "cut at \(whole.distance(from: whole.startIndex, to: cut))")
        }
    }

    func testAPercentEncodedPathIsDecoded() {
        var reader = WorkingDirectoryReader()
        XCTAssertEqual(reader.read(report("/home/me/My%20Files")), "/home/me/My Files")
        XCTAssertEqual(WorkingDirectoryReader.path(in: "file:///tmp"), "/tmp", "a report without a host")
        XCTAssertNil(WorkingDirectoryReader.path(in: "not a url"))
    }

    func testAReportThatNeverEndsIsGivenUp() {
        var reader = WorkingDirectoryReader()
        XCTAssertNil(reader.read("\u{1B}]7;file://h/" + String(repeating: "x", count: 5000)))
        XCTAssertEqual(reader.read(report("/next")), "/next")
    }

    func testShellIntegrationIsOffUntilTurnedOn() {
        var machine = RDMachine(remoteAddress: "web-01", remotePort: "22")
        XCTAssertFalse(machine.shellIntegration)
        machine.shellIntegration = true
        XCTAssertEqual(machine.attachment["shell.integration"], "1")
        machine.shellIntegration = false
        XCTAssertNil(machine.attachment["shell.integration"])
    }

    @MainActor
    func testTheLatestReportOfAServerIsKept() {
        let directories = TerminalDirectories.shared
        let server = UUID()
        directories.report("/a", for: server)
        let first = directories.latest[server]
        directories.report("/a", for: server)
        XCTAssertEqual(directories.latest[server], first, "the same folder again is no change")
        directories.report("/b", for: server)
        directories.report("/a", for: server)
        XCTAssertEqual(directories.latest[server]?.path, "/a")
        XCTAssertNotEqual(directories.latest[server]?.serial, first?.serial, "back in a folder after leaving it is a change")
    }
}
