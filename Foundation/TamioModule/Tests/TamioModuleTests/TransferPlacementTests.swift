//
//  TransferPlacementTests.swift
//  TamioModuleTests
//

@testable import TamioModule
import XCTest

final class TransferPlacementTests: XCTestCase {
    func testFreeNameNumbersBeforeTheExtension() {
        XCTAssertEqual(TransferPlacement.freeName(for: "notes.txt", isDirectory: false, taken: ["notes.txt"]), "notes 2.txt")
        XCTAssertEqual(TransferPlacement.freeName(for: "notes.txt", isDirectory: false, taken: ["notes.txt", "notes 2.txt"]), "notes 3.txt")
    }

    func testFreeNameKeepsAFoldersDotsAndADotfileWhole() {
        XCTAssertEqual(TransferPlacement.freeName(for: "site.v2", isDirectory: true, taken: ["site.v2"]), "site.v2 2")
        XCTAssertEqual(TransferPlacement.freeName(for: ".bashrc", isDirectory: false, taken: [".bashrc"]), ".bashrc 2")
    }

    func testAFreeNameGoesAsItIs() {
        var existing = ["other": false]
        let place = TransferPlacement.place("a.txt", isDirectory: false, among: &existing, .skip)
        XCTAssertEqual(place?.name, "a.txt")
        XCTAssertEqual(place?.clearing, false)
        XCTAssertEqual(existing["a.txt"], false)
    }

    func testSkipLeavesATakenNameOut() {
        var existing = ["a.txt": false]
        XCTAssertNil(TransferPlacement.place("a.txt", isDirectory: false, among: &existing, .skip))
    }

    func testReplaceClearsOnlyWhenTheKindsDiffer() {
        var existing = ["a": false, "b": true, "c": true]
        XCTAssertEqual(TransferPlacement.place("a", isDirectory: false, among: &existing, .replace)?.clearing, false)
        // A folder onto a folder merges.
        XCTAssertEqual(TransferPlacement.place("b", isDirectory: true, among: &existing, .replace)?.clearing, false)
        XCTAssertEqual(TransferPlacement.place("c", isDirectory: false, among: &existing, .replace)?.clearing, true)
    }

    func testKeepBothTakesTheNameItGives() {
        var existing = ["a.txt": false]
        XCTAssertEqual(TransferPlacement.place("a.txt", isDirectory: false, among: &existing, .keepBoth)?.name, "a 2.txt")
        // A second item of the same name in the same job does not land on it.
        XCTAssertEqual(TransferPlacement.place("a.txt", isDirectory: false, among: &existing, .keepBoth)?.name, "a 3.txt")
    }

    // MARK: Within this Mac

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tamio-placement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("from"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("to"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ path: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func copy(_ collision: TransferJob.Collision) throws {
        try TransferPlacement.copyLocally([root.appendingPathComponent("from/a.txt").path], into: root.appendingPathComponent("to").path, collision)
    }

    func testLocalKeepBothLeavesTheOneThere() throws {
        try write("new", "from/a.txt")
        try write("old", "to/a.txt")
        try copy(.keepBoth)
        XCTAssertEqual(read("to/a.txt"), "old")
        XCTAssertEqual(read("to/a 2.txt"), "new")
    }

    // Replace over a file is left untested here: it sends the file to the
    // real Trash.

    func testLocalSkipChangesNothing() throws {
        try write("new", "from/a.txt")
        try write("old", "to/a.txt")
        try copy(.skip)
        XCTAssertEqual(read("to/a.txt"), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("to").path), ["a.txt"])
    }

    func testLocalReplaceOntoItselfKeepsTheFile() throws {
        try write("same", "from/a.txt")
        try TransferPlacement.copyLocally([root.appendingPathComponent("from/a.txt").path], into: root.appendingPathComponent("from").path, .replace)
        XCTAssertEqual(read("from/a.txt"), "same")
    }
}
