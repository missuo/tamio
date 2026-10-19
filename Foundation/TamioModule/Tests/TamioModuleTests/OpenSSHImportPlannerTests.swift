@testable import TamioModule
import XCTest

final class OpenSSHImportPlannerTests: XCTestCase {
    private let source = "/tmp/tamio-planner-test/config"

    private func fixture(_ alias: String = "production", options: [String: [String]] = [:], directives: Set<String> = []) -> (OpenSSHScan, OpenSSHResolvedHost) {
        let candidate = OpenSSHHostCandidate(alias: alias, source: OpenSSHSourceLocation(path: source, line: 7))
        let scan = OpenSSHScan(sourcePath: source, hosts: [candidate], warnings: [], requiresTrust: false, directives: directives)
        var values = ["hostname": ["example.com"], "port": ["2222"], "user": ["deploy"]]
        values.merge(options) { _, new in new }
        return (scan, OpenSSHResolvedHost(candidate: candidate, options: values))
    }

    private func plan(_ options: [String: [String]] = [:], machines: [RDMachine] = [], identities: [RDIdentity] = [], directives: Set<String> = []) -> OpenSSHImportCandidate {
        let (scan, host) = fixture(options: options, directives: directives)
        return OpenSSHImportPlanner.plan(scan: scan, resolved: [host], machines: machines, identities: identities)[0]
    }

    private func selection(_ alias: String = "production", credential: OpenSSHCredentialChoice = .none, replace: Bool = false, acknowledge: Bool = true) -> OpenSSHImportSelection {
        OpenSSHImportSelection(alias: alias, credential: credential, replaceExisting: replace, acknowledgeWarnings: acknowledge)
    }

    func testResolvedValuesAndExplicitDraftConsent() throws {
        let candidate = plan()
        XCTAssertEqual(candidate.machine.remoteAddress, "example.com")
        XCTAssertEqual(candidate.machine.remotePort, "2222")
        XCTAssertEqual(candidate.machine.username, "deploy")
        XCTAssertEqual(candidate.status, .needsCredentials)
        XCTAssertTrue(candidate.canImport)
        XCTAssertThrowsError(try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection(acknowledge: false)], machines: [], identities: []))
        let batch = try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection()], machines: [], identities: [])
        XCTAssertEqual(batch.created, 1)
        XCTAssertNil(batch.machines[0].associatedIdentity)
        XCTAssertTrue(batch.identities.isEmpty)
    }

    func testExistingSourceUpdatePreservesNonImportedFields() throws {
        var machine = plan().machine
        machine.group = "Work"
        machine.tags = ["critical"]
        machine.comment = "Keep this"
        machine.fileTransferLoginPath = "/srv"
        machine.startupSnippet = UUID()
        machine.lastConnection = Date(timeIntervalSince1970: 123)
        machine.lastBanner = "banner"
        machine.name = "My production server"
        let candidate = plan(["hostname": ["new.example.com"]], machines: [machine])
        XCTAssertEqual(candidate.existing?.id, machine.id)
        XCTAssertThrowsError(try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection()], machines: [machine], identities: []))
        let batch = try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection(replace: true)], machines: [machine], identities: [])
        var expected = machine
        expected.remoteAddress = "new.example.com"
        XCTAssertEqual(batch.machines, [expected])
        XCTAssertEqual(batch.updated, 1)
        XCTAssertEqual(batch.created, 0)
    }

    func testUnchangedImportIsNotReadyAndRequiresExplicitReplacement() {
        let saved = plan().machine
        let candidate = plan(machines: [saved])
        XCTAssertEqual(candidate.status, .alreadyExists)
        XCTAssertThrowsError(try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection()], machines: [saved], identities: []))
    }

    func testManualAliasConflictAndAmbiguousDuplicates() {
        let manual = RDMachine(remoteAddress: "elsewhere.example", remotePort: "22", name: "production")
        let candidate = plan(machines: [manual])
        XCTAssertEqual(candidate.existing, manual)
        XCTAssertNotEqual(candidate.status, .ready)
        XCTAssertFalse(plan(machines: [manual, RDMachine(name: "production")]).canImport)
    }

    func testStaleStoreAndRepeatedSelectionsAbortWholeBatch() {
        let candidate = plan()
        XCTAssertThrowsError(try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection(), selection()], machines: [], identities: []))
        XCTAssertThrowsError(try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection()], machines: [RDMachine(name: "production")], identities: []))
        let saved = candidate.machine
        let update = plan(machines: [saved])
        var changed = saved
        changed.comment = "Changed after review"
        XCTAssertThrowsError(try OpenSSHImportPlanner.prepare(candidates: [update], selections: [selection(replace: true)], machines: [changed], identities: []))
    }

    func testAliasesSharingEndpointRemainIndependentlyImportable() throws {
        var saved = RDMachine(remoteAddress: "example.com", remotePort: "2222", name: "existing")
        saved.username = "deploy"
        let (scan, first) = fixture()
        let (_, second) = fixture("other")
        let candidates = OpenSSHImportPlanner.plan(scan: scan, resolved: [first, second], machines: [saved], identities: [])
        XCTAssertTrue(candidates.allSatisfy { $0.existing == nil })
        let batch = try OpenSSHImportPlanner.prepare(candidates: candidates, selections: [selection(), selection("other")], machines: [saved], identities: [])
        XCTAssertEqual(batch.created, 2)
        XCTAssertEqual(batch.machines.count, 3)
    }

    func testExplicitUpdateKeepsOwnPrivateCredential() throws {
        var identity = RDIdentity(password: "fixture")
        identity.isPrivate = true
        var saved = plan().machine
        saved.associatedIdentity = identity.id.uuidString
        let candidate = plan(machines: [saved], identities: [identity])
        let batch = try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection(credential: .existing(identity.id), replace: true)], machines: [saved], identities: [identity])
        XCTAssertEqual(batch.machines[0].associatedIdentity, identity.id.uuidString)
        XCTAssertEqual(batch.identities, [identity])
    }

    func testUnknownExplicitPoliciesAndPKCS11AreDiagnosed() {
        let candidate = plan(directives: ["rekeylimit", "escapechar", "hostbasedacceptedalgorithms"])
        XCTAssertTrue(candidate.diagnostics.contains { $0.contains("rekeylimit") })
        XCTAssertFalse(plan(["pkcs11provider": ["/usr/lib/provider.dylib"]]).canImport)
    }

    func testNativeDefaultSecurityProviderDoesNotRejectSoftwareKeys() {
        let ordinary = plan(["securitykeyprovider": ["$SSH_SK_PROVIDER"]])
        XCTAssertTrue(ordinary.canImport)
        XCTAssertEqual(ordinary.status, .needsCredentials)
        XCTAssertFalse(plan(["securitykeyprovider": ["/custom/provider"]], directives: ["securitykeyprovider"]).canImport)
    }

    func testIdentityPathReuseDoesNotRequireReadablePrivateFile() throws {
        let path = "/does/not/exist/key"
        let identity = RDIdentity(privateKey: "stored-key", attachment: [OpenSSHImportCredentials.sourceKey: path])
        let candidate = plan(["identityfile": [path]], identities: [identity])
        XCTAssertEqual(candidate.machine.associatedIdentity, identity.id.uuidString)
        XCTAssertEqual(candidate.status, .needsReview)
        let batch = try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection(credential: .existing(identity.id))], machines: [], identities: [identity])
        XCTAssertEqual(batch.identities, [identity])
    }

    func testMultipleIdentityFilesNeverSilentlySelectFirst() {
        let identity = RDIdentity(privateKey: "stored-key", attachment: [OpenSSHImportCredentials.sourceKey: "/key/first"])
        let candidate = plan(["identityfile": ["/key/first", "/key/second"]], identities: [identity])
        XCTAssertNil(candidate.machine.associatedIdentity)
        XCTAssertEqual(candidate.identityFiles.count, 2)
        XCTAssertEqual(candidate.status, .needsCredentials)
    }

    func testCertificatesAndUnknownProxyTokensAreUnsupported() {
        XCTAssertFalse(plan(["certificatefile": ["/key-cert.pub"]]).canImport)
        XCTAssertFalse(plan(["proxycommand": ["nc %r@%h %p"]]).canImport)
        XCTAssertFalse(plan(["proxyusefdpass": ["yes"]]).canImport)
        XCTAssertFalse(plan(["hostname": ["bad;touch /tmp/marker"]]).canImport)
        XCTAssertFalse(plan(["port": ["65536"]]).canImport)
    }

    func testIgnoredRulesAndAgentForwardingRequireReview() {
        let identity = RDIdentity(password: "fixture", attachment: [OpenSSHImportCredentials.sourceKey: "/key"])
        let candidate = plan(["identityfile": ["/key"], "forwardagent": ["yes"], "localforward": ["8080 localhost:80"]], identities: [identity], directives: ["match", "ciphers", "stricthostkeychecking"])
        XCTAssertEqual(candidate.status, .needsReview)
        XCTAssertTrue(candidate.diagnostics.contains { $0.contains("Match") })
        XCTAssertTrue(candidate.diagnostics.contains { $0.contains("agent") })
        XCTAssertTrue(candidate.diagnostics.contains { $0.contains("forwarding") })
        XCTAssertTrue(candidate.diagnostics.contains { $0.contains("ciphers") })
    }

    func testProxyJumpQuotesLiteralsAndEscapesEnginePercents() throws {
        let command = try OpenSSHImportProxy.jumpCommand("alice@jump-one:2200,bob@[::1]:2201", source: "/tmp/config's %h $(touch marker)", host: "2001:db8::1", port: "2222")
        XCTAssertEqual(command, "'/usr/bin/ssh' '-F' '/tmp/config'\\''s %%h $(touch marker)' '-W' '[2001:db8::1]:2222' '-J' 'alice@jump-one:2200' '-l' 'bob' '-p' '2201' '--' '::1'")
        XCTAssertThrowsError(try OpenSSHImportProxy.jumpCommand("-oProxyCommand=bad", source: source, host: "example.com", port: "22"))
        XCTAssertThrowsError(try OpenSSHImportProxy.jumpCommand("host,", source: source, host: "example.com", port: "22"))
        XCTAssertThrowsError(try OpenSSHImportProxy.jumpCommand("host:0", source: source, host: "example.com", port: "22"))
        XCTAssertThrowsError(try OpenSSHImportProxy.jumpCommand("host;touch-marker", source: source, host: "example.com", port: "22"))
    }

    func testProxyCommandSupportedTokensRemainUnchanged() {
        let command = "nc '%h' '%p'; printf '%%'"
        let candidate = plan(["proxycommand": [command]])
        XCTAssertEqual(candidate.machine.proxyCommand, command)
        XCTAssertTrue(candidate.canImport)
        XCTAssertFalse(candidate.diagnostics.isEmpty)
    }

    func testPrivateAndMissingIdentitiesCannotBeReused() {
        let candidate = plan()
        var identity = RDIdentity(password: "fixture")
        identity.isPrivate = true
        XCTAssertThrowsError(try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection(credential: .existing(identity.id))], machines: [], identities: [identity]))
        XCTAssertThrowsError(try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection(credential: .existing(UUID()))], machines: [], identities: []))
    }

    func testExplicitKeyImportDeduplicatesWithinBatchAndAgainstPublicKey() throws {
        #if os(macOS)
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pair = SSHKeyGenerator
                .ed25519(seed: Data(repeating: 7, count: 32), comment: "fixture", check: 123)
            let file = directory.appendingPathComponent("key")
            try pair.privateKey.write(to: file, atomically: true, encoding: .utf8)
            let (scan, first) = fixture()
            let (_, second) = fixture("other", options: ["hostname": ["other.example.com"]])
            let candidates = OpenSSHImportPlanner.plan(scan: scan, resolved: [first, second], machines: [], identities: [])
            let selections = [selection(credential: .importFile(file.path, passphrase: "")), selection("other", credential: .importFile(file.path, passphrase: ""))]
            let batch = try OpenSSHImportPlanner.prepare(candidates: candidates, selections: selections, machines: [], identities: [])
            XCTAssertEqual(batch.identities.count, 1)
            XCTAssertEqual(batch.machines[0].associatedIdentity, batch.machines[1].associatedIdentity)
            XCTAssertFalse(batch.identities[0].authenticAutomatically)
            let existing = RDIdentity(privateKey: pair.privateKey, publicKey: pair.publicKey)
            let reused = try OpenSSHImportPlanner.prepare(candidates: [candidates[0]], selections: [selections[0]], machines: [], identities: [existing])
            XCTAssertEqual(reused.identities, [existing])
            XCTAssertEqual(reused.machines[0].associatedIdentity, existing.id.uuidString)
        #endif
    }

    func testPublicSidecarReuseAndMalformedExplicitImport() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pair = SSHKeyGenerator
            .ed25519(seed: Data(repeating: 8, count: 32), comment: "fixture", check: 456)
        let path = directory.appendingPathComponent("key")
        try pair.publicKey.write(to: path.appendingPathExtension("pub"), atomically: true, encoding: .utf8)
        let identity = RDIdentity(privateKey: "stored-key", publicKey: pair.publicKey)
        XCTAssertEqual(plan(["identityfile": [path.path]], identities: [identity]).machine.associatedIdentity, identity.id.uuidString)
        try "not a private key".write(to: path, atomically: true, encoding: .utf8)
        let candidate = plan()
        XCTAssertThrowsError(try OpenSSHImportPlanner.prepare(candidates: [candidate], selections: [selection(credential: .importFile(path.path, passphrase: ""))], machines: [], identities: []))
        XCTAssertThrowsError(try OpenSSHImportCredentials.readRegularFile(directory.path, limit: 1024))
    }

    func testEncryptedKeyRequiresCorrectExplicitPassphrase() throws {
        #if os(macOS)
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let pair = SSHKeyGenerator
                .ed25519(seed: Data(repeating: 9, count: 32), comment: "fixture", check: 789)
            let key = directory.appendingPathComponent("key")
            try pair.privateKey.write(to: key, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-p", "-P", "", "-N", "fixture-passphrase", "-f", key.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertThrowsError(try OpenSSHImportCredentials.importKey(path: key.path, passphrase: "wrong", identities: []))
            let identity = try OpenSSHImportCredentials.importKey(path: key.path, passphrase: "fixture-passphrase", identities: [])
            XCTAssertEqual(identity.password, "fixture-passphrase")
            XCTAssertEqual(OpenSSHImportCredentials.publicMaterial(identity.publicKey), OpenSSHImportCredentials.publicMaterial(pair.publicKey))
        #endif
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tamio-planner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
}
