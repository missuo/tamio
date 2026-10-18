//
//  GroupPersistenceTests.swift
//  TamioModuleTests
//

@testable import TamioModule
import XCTest

/// The groups persist as PropertyLists (encrypted into UserDefaults) with
/// user data already on disk. These fixtures are the layout the pre-generic
/// types wrote, hardcoded key for key: the shared RDGroup core must decode
/// them, and re-encoding must produce the same key set.
final class GroupPersistenceTests: XCTestCase {
    private func plistData(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    /// The top-level key set of an encoded group, and the key set of each
    /// item of the one array it holds.
    private func keySets(of data: Data) throws -> (top: Set<String>, items: [Set<String>]) {
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        var itemKeys: [Set<String>] = []
        for value in plist.values {
            if let items = value as? [[String: Any]] {
                itemKeys = items.map { Set($0.keys) }
            }
        }
        return (Set(plist.keys), itemKeys)
    }

    func testMachineGroupReadsTheLegacyLayout() throws {
        let legacy: [String: Any] = [
            "id": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            "machines": [[
                "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                "remoteAddress": "192.0.2.10",
                "remotePort": "2222",
                "name": "alpha",
                "group": "prod",
                "lastConnection": Date(timeIntervalSince1970: 1_700_000_000),
                "lastBanner": "OpenSSH",
                "comment": "web",
                "associatedIdentity": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                "attachment": ["k": "v"],
            ], [
                "id": "99999999-9999-9999-9999-999999999999",
                "remoteAddress": "192.0.2.11",
                "remotePort": "22",
                "name": "beta",
                "group": "",
                "lastConnection": Date(timeIntervalSince1970: 1_700_000_100),
                "lastBanner": "",
                "comment": "",
                "attachment": [:],
            ]],
        ]
        let group = try PropertyListDecoder().decode(RDMachineGroup.self, from: plistData(legacy))
        XCTAssertEqual(group.id, UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
        XCTAssertEqual(group.machines.count, 2)
        let machine = group.machines[0]
        XCTAssertEqual(machine.id, UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        XCTAssertEqual(machine.remoteAddress, "192.0.2.10")
        XCTAssertEqual(machine.remotePort, "2222")
        XCTAssertEqual(machine.name, "alpha")
        XCTAssertEqual(machine.group, "prod")
        XCTAssertEqual(machine.lastConnection, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(machine.lastBanner, "OpenSSH")
        XCTAssertEqual(machine.comment, "web")
        XCTAssertEqual(machine.associatedIdentity, "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        XCTAssertEqual(machine.attachment, ["k": "v"])
        XCTAssertEqual(machine.proxyCommand, "", "a server saved before proxy commands connects directly")
        XCTAssertNil(group.machines[1].associatedIdentity)

        let reencoded = try PropertyListEncoder().encode(group)
        let keys = try keySets(of: reencoded)
        XCTAssertEqual(keys.top, ["id", "machines"])
        XCTAssertEqual(keys.items, [
            ["associatedIdentity", "attachment", "comment", "group", "id", "lastBanner", "lastConnection", "name", "remoteAddress", "remotePort"],
            // An unset optional stays absent, as encodeIfPresent wrote it.
            ["attachment", "comment", "group", "id", "lastBanner", "lastConnection", "name", "remoteAddress", "remotePort"],
        ])
        XCTAssertEqual(try PropertyListDecoder().decode(RDMachineGroup.self, from: reencoded), group)
    }

    func testIdentityGroupReadsTheLegacyLayout() throws {
        let legacy: [String: Any] = [
            "id": "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD",
            "identities": [[
                "id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                "username": "root",
                "password": "pw",
                "privateKey": "",
                "publicKey": "",
                "lastRecentUsed": Date(timeIntervalSince1970: 1_700_000_100),
                "comment": "c",
                "group": "g",
                "authenticAutomatically": false,
                "attachment": ["ik": "iv"],
            ]],
        ]
        let group = try PropertyListDecoder().decode(RDIdentityGroup.self, from: plistData(legacy))
        XCTAssertEqual(group.id, UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"))
        XCTAssertEqual(group.identities.count, 1)
        let identity = group.identities[0]
        XCTAssertEqual(identity.id, UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        XCTAssertEqual(identity.username, "root")
        XCTAssertEqual(identity.password, "pw")
        XCTAssertEqual(identity.lastRecentUsed, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(identity.comment, "c")
        XCTAssertEqual(identity.group, "g")
        XCTAssertFalse(identity.authenticAutomatically)
        XCTAssertEqual(identity.attachment, ["ik": "iv"])

        let reencoded = try PropertyListEncoder().encode(group)
        let keys = try keySets(of: reencoded)
        XCTAssertEqual(keys.top, ["id", "identities"])
        XCTAssertEqual(keys.items, [["attachment", "authenticAutomatically", "comment", "group", "id", "lastRecentUsed", "password", "privateKey", "publicKey", "username"]])
        XCTAssertEqual(try PropertyListDecoder().decode(RDIdentityGroup.self, from: reencoded).identities, group.identities)
    }

    func testSnippetGroupReadsTheLegacyLayout() throws {
        let legacy: [String: Any] = [
            "id": "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
            "snippets": [[
                "id": "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE",
                "name": "uptime",
                "group": "diag",
                "code": "uptime",
                "comment": "sc",
                "attachment": ["sk": "sv"],
            ]],
        ]
        let group = try PropertyListDecoder().decode(RDSnippetGroup.self, from: plistData(legacy))
        XCTAssertEqual(group.id, UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        XCTAssertEqual(group.snippets.count, 1)
        let snippet = group.snippets[0]
        XCTAssertEqual(snippet.id, UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"))
        XCTAssertEqual(snippet.name, "uptime")
        XCTAssertEqual(snippet.group, "diag")
        XCTAssertEqual(snippet.code, "uptime")
        XCTAssertEqual(snippet.comment, "sc")
        XCTAssertEqual(snippet.attachment, ["sk": "sv"])

        let reencoded = try PropertyListEncoder().encode(group)
        let keys = try keySets(of: reencoded)
        XCTAssertEqual(keys.top, ["id", "snippets"])
        XCTAssertEqual(keys.items, [["attachment", "code", "comment", "group", "id", "name"]])
        XCTAssertEqual(try PropertyListDecoder().decode(RDSnippetGroup.self, from: reencoded), group)
    }

    func testPortForwardGroupReadsTheLegacyLayout() throws {
        let legacy: [String: Any] = [
            "id": "22222222-2222-2222-2222-222222222222",
            "forwards": [[
                "id": "11111111-1111-1111-1111-111111111111",
                "forwardOrientation": "Remote",
                "bindPort": 8080,
                "targetHost": "127.0.0.1",
                "targetPort": 80,
                "usingMachine": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                "attachment": ["fk": "fv"],
            ], [
                "id": "33333333-3333-3333-3333-333333333333",
                "forwardOrientation": "Local",
                "bindPort": 9090,
                "targetHost": "localhost",
                "targetPort": 22,
                "attachment": [:],
            ]],
        ]
        let group = try PropertyListDecoder().decode(RDPortForwardGroup.self, from: plistData(legacy))
        XCTAssertEqual(group.id, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(group.forwards.count, 2)
        let forward = group.forwards[0]
        XCTAssertEqual(forward.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(forward.forwardOrientation, .listenRemote)
        XCTAssertEqual(forward.bindPort, 8080)
        XCTAssertEqual(forward.targetHost, "127.0.0.1")
        XCTAssertEqual(forward.targetPort, 80)
        XCTAssertEqual(forward.usingMachine, UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        XCTAssertEqual(forward.attachment, ["fk": "fv"])
        XCTAssertNil(group.forwards[1].usingMachine)

        let reencoded = try PropertyListEncoder().encode(group)
        let keys = try keySets(of: reencoded)
        XCTAssertEqual(keys.top, ["forwards", "id"])
        XCTAssertEqual(keys.items, [
            ["attachment", "bindPort", "forwardOrientation", "id", "targetHost", "targetPort", "usingMachine"],
            ["attachment", "bindPort", "forwardOrientation", "id", "targetHost", "targetPort"],
        ])
        XCTAssertEqual(try PropertyListDecoder().decode(RDPortForwardGroup.self, from: reencoded), group)
    }
}
