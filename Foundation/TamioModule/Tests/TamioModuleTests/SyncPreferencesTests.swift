//
//  SyncPreferencesTests.swift
//  TamioModuleTests
//
//  Settings synced between two devices: each preference on its own, and one
//  a device does not know of left as it was stored.
//

@testable import TamioModule
import XCTest

final class SyncPreferencesTests: XCTestCase {
    private struct Device {
        var values: [String: SyncedPreference.Value] = [:]
        /// The preferences this device has; by default the ones it holds.
        var keys: Set<String>?
        var state = SyncState()
        var key: SyncCipher.Key?

        mutating func sync(_ cloud: inout Data?, at now: Date) {
            var input = SyncInput(
                machines: [], identities: [], state: state, passphrase: "correct horse battery", remote: cloud, key: key
            )
            input.preferences = values.map { PreferenceItem(key: $0.key, value: $0.value) }
            input.preferenceKeys = keys ?? Set(values.keys)
            input.now = now
            input.rounds = 1000
            input.minimumRounds = 1000
            guard case let .done(done) = SyncSession.run(input) else { return XCTFail("sync failed") }
            for change in done.preferences {
                if case let .put(item) = change { values[item.key] = item.value }
            }
            state = done.state
            key = done.key
            if let upload = done.upload { cloud = upload }
        }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testSettingsReachTheOtherDevice() {
        var cloud: Data?
        var mine = Device(values: ["appearance": .string("dark"), "timeout": .int(10), "hidden": .bool(true)])
        mine.sync(&cloud, at: start)

        var theirs = Device(values: ["appearance": .string("system"), "timeout": .int(5), "hidden": .bool(false)])
        theirs.sync(&cloud, at: start.addingTimeInterval(1))
        XCTAssertEqual(theirs.values, mine.values, "a device that never synced takes what is stored")
    }

    func testEachSettingKeepsItsOwnLatestChange() {
        var cloud: Data?
        var mine = Device(values: ["appearance": .string("system"), "timeout": .int(5)])
        mine.sync(&cloud, at: start)
        var theirs = Device(values: mine.values)
        theirs.sync(&cloud, at: start.addingTimeInterval(1))

        mine.values["appearance"] = .string("dark")
        theirs.values["timeout"] = .int(20)
        mine.sync(&cloud, at: start.addingTimeInterval(10))
        theirs.sync(&cloud, at: start.addingTimeInterval(11))
        mine.sync(&cloud, at: start.addingTimeInterval(12))

        let expected: [String: SyncedPreference.Value] = ["appearance": .string("dark"), "timeout": .int(20)]
        XCTAssertEqual(mine.values, expected)
        XCTAssertEqual(theirs.values, expected)
    }

    func testASettingThisDeviceLacksIsKept() {
        var cloud: Data?
        var mine = Device(values: ["appearance": .string("dark"), "terminal": .data(Data("font-size".utf8))])
        mine.sync(&cloud, at: start)

        // An iPhone, or an older Tamio, without the terminal's configuration.
        var theirs = Device(values: ["appearance": .string("dark")], keys: ["appearance"])
        theirs.sync(&cloud, at: start.addingTimeInterval(1))
        XCTAssertNil(theirs.values["terminal"], "it is not put on a device that does not have it")
        theirs.values["appearance"] = .string("light")
        theirs.sync(&cloud, at: start.addingTimeInterval(2))
        theirs.sync(&cloud, at: start.addingTimeInterval(3))

        var third = Device()
        third.keys = ["appearance", "terminal"]
        third.sync(&cloud, at: start.addingTimeInterval(4))
        XCTAssertEqual(third.values["terminal"], .data(Data("font-size".utf8)))
        XCTAssertEqual(third.values["appearance"], .string("light"))
    }

    func testAPreferenceHasTheSameIDOnEveryDevice() {
        XCTAssertEqual(PreferenceItem.id(for: "sb.moe.tamio.timeout"), PreferenceItem(key: "sb.moe.tamio.timeout", value: .int(5)).id)
        XCTAssertNotEqual(PreferenceItem.id(for: "a"), PreferenceItem.id(for: "b"))
    }

    func testAnUnchangedRoundUploadsNothing() {
        var cloud: Data?
        var mine = Device(values: ["appearance": .string("dark")])
        mine.sync(&cloud, at: start)
        let stored = cloud
        mine.sync(&cloud, at: start.addingTimeInterval(5))
        XCTAssertEqual(cloud, stored)
    }
}
