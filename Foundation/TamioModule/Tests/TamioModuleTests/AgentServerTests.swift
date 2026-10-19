//
//  AgentServerTests.swift
//  TamioModuleTests
//
//  The MCP server must never hand an agent a password, a private key or a
//  passphrase. These tests save secrets in the store, call every read tool
//  and resource, and look for the secrets in what comes back.
//

import NSRemoteShell
@testable import TamioModule
import XCTest

@MainActor
final class AgentServerTests: XCTestCase {
    let password = "hunter2-SECRET-password"
    let passphrase = "SECRET-passphrase-9"
    var key: SSHKeyGenerator.KeyPair!
    var keyBody: String!
    var machines: [RDMachine.ID] = []
    var identities: [RDIdentity.ID] = []

    override func setUp() async throws {
        key = SSHKeyGenerator.ed25519(comment: "agent-test")
        // The base64 body of the private key, without its armour lines.
        keyBody = key.privateKey.split(separator: "\n").dropFirst().dropLast().joined()
        let store = TamioStore.shared

        var keyIdentity = RDIdentity(authenticAutomatically: false)
        keyIdentity.name = "Agent test key"
        keyIdentity.privateKey = key.privateKey
        keyIdentity.publicKey = key.publicKey
        keyIdentity.password = passphrase
        store.identityGroup.insert(keyIdentity)

        var ownPassword = RDIdentity(authenticAutomatically: false)
        ownPassword.password = password
        ownPassword.isPrivate = true
        store.identityGroup.insert(ownPassword)
        identities = [keyIdentity.id, ownPassword.id]

        var keyed = RDMachine(remoteAddress: "10.9.8.7", remotePort: "2222", name: "agent-test-key")
        keyed.username = "deploy"
        keyed.associatedIdentity = keyIdentity.id.uuidString
        keyed.proxyCommand = "cloudflared access ssh --hostname %h"
        var passworded = RDMachine(remoteAddress: "10.9.8.6", remotePort: "22", name: "agent-test-password", group: "Agent Tests")
        passworded.associatedIdentity = ownPassword.id.uuidString
        store.machineGroup.insert(keyed)
        store.machineGroup.insert(passworded)
        machines = [keyed.id, passworded.id]
    }

    override func tearDown() async throws {
        for id in machines { TamioStore.shared.machineGroup.delete(id) }
        for id in identities { TamioStore.shared.identityGroup.delete(id) }
    }

    func call(_ method: String, _ params: JSONValue = [:]) async -> String {
        let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]
        return await AgentServer().handle(request.encodedString(), client: AgentSession()) ?? ""
    }

    func assertNoSecret(_ reply: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(reply.isEmpty, file: file, line: line)
        for secret in [password, passphrase, key.privateKey, keyBody!, "PRIVATE KEY"] {
            XCTAssertFalse(reply.contains(secret), "a reply holds a secret: \(secret.prefix(16))…", file: file, line: line)
        }
    }

    func testNoReadToolReturnsASecret() async {
        let reads: [(String, JSONValue)] = [
            ("list_hosts", [:]),
            ("get_host", ["host": "agent-test-key"]),
            ("get_host", ["host": "agent-test-password"]),
            ("get_metrics", [:]),
            ("export_ssh_config", [:]),
            ("list_identities", [:]),
            ("list_snippets", [:]),
            ("list_port_forwards", [:]),
            ("get_activity", [:]),
        ]
        for (tool, arguments) in reads {
            assertNoSecret(await call("tools/call", ["name": .string(tool), "arguments": arguments]))
        }
        assertNoSecret(await call("resources/read", ["uri": "tamio://hosts"]))
        assertNoSecret(await call("tools/list"))
    }

    func testHostsCarryTheirConnectionDetails() async {
        let reply = await call("tools/call", ["name": "get_host", "arguments": ["host": "agent-test-key"]])
        XCTAssertTrue(reply.contains("10.9.8.7"))
        XCTAssertTrue(reply.contains("2222"))
        XCTAssertTrue(reply.contains("deploy"))
        XCTAssertTrue(reply.contains("Agent test key"))
        XCTAssertTrue(reply.contains("ed25519"))
        let config = await call("tools/call", ["name": "export_ssh_config", "arguments": ["hosts": ["agent-test-password"]]])
        XCTAssertTrue(config.contains("User root"), "a server without a user signs in as root")
        XCTAssertTrue(reply.contains("cloudflared access ssh --hostname %h"), "the proxy command is part of the server")
        let proxied = await call("tools/call", ["name": "export_ssh_config", "arguments": ["hosts": ["agent-test-key"]]])
        XCTAssertTrue(proxied.contains("ProxyCommand cloudflared access ssh --hostname %h"))
        XCTAssertFalse(config.contains("ProxyCommand"), "a server without one connects directly")
    }

    func testProxyCommandSurvivesSavingAndSearching() {
        var machine = RDMachine(remoteAddress: "bastion.example.test", remotePort: "22", name: "bastion")
        XCTAssertEqual(machine.proxyCommand, "")
        machine.proxyCommand = "  cloudflared access ssh --hostname %h  "
        XCTAssertEqual(machine.proxyCommand, "cloudflared access ssh --hostname %h")
        XCTAssertEqual(machine.attachment["proxy.command"], machine.proxyCommand)
        machine.proxyCommand = "   "
        XCTAssertEqual(machine.proxyCommand, "")
        XCTAssertNil(machine.attachment["proxy.command"], "an empty command is not saved")

        machine.proxyCommand = "cloudflared access ssh --hostname %h"
        XCTAssertTrue(machine.isQualifiedForSearch(text: "cloudflared"))
        XCTAssertFalse(RDMachine().isQualifiedForSearch(text: "cloudflared"))

        let command = machine.getCommand()
        XCTAssertTrue(command.contains("-o ProxyCommand=\"cloudflared access ssh --hostname %h\""))
        XCTAssertFalse(RDMachine(remoteAddress: "192.0.2.1", remotePort: "22").getCommand().contains("ProxyCommand"))

        machine.proxyCommand = "nc -X connect -x \"proxy:1080\" %h %p"
        XCTAssertTrue(machine.getCommand().contains("-o ProxyCommand=\"nc -X connect -x \\\"proxy:1080\\\" %h %p\""))

        let config = AgentHost(machine).sshConfigBlock
        XCTAssertTrue(config.contains("ProxyCommand nc -X connect -x \"proxy:1080\" %h %p"))
        XCTAssertFalse(AgentHost(RDMachine()).sshConfigBlock.contains("ProxyCommand"))
    }

    func testASignInWithNoCredentialsIsKeptWithTheServer() {
        var machine = RDMachine(remoteAddress: "ts-host", remotePort: "22", name: "ts")
        XCTAssertFalse(machine.signsInWithoutCredentials)
        XCTAssertEqual(AgentHost(machine).auth, "missing", "nothing to sign in with")
        machine.signsInWithoutCredentials = true
        XCTAssertEqual(machine.attachment["auth"], "none", "kept with the server, so it syncs like its other settings")
        XCTAssertEqual(AgentHost(machine).auth, "none")
        XCTAssertNil(AgentHost(machine).identity)
        machine.signsInWithoutCredentials = false
        XCTAssertNil(machine.attachment["auth"])
    }

    func testProxyCommandExpandsPlaceholdersAndReportsFailure() {
        var machine = RDMachine(remoteAddress: "bastion.example.test", remotePort: "2222", name: "bastion")
        machine.proxyCommand = "echo 'tunnel refused for %h:%p (100%%)' >&2; exit 1"
        let shell = NSRemoteShell.configured(for: machine, timeout: 2)
        shell.requestConnectAndWait()
        XCTAssertFalse(shell.isConnected)
        XCTAssertEqual(shell.getLastError(), "tunnel refused for bastion.example.test:2222 (100%)")
        shell.destroyPermanently()

        var unsafeHost = RDMachine(remoteAddress: "bastion.example.test; touch /tmp/bad", remotePort: "22", name: "unsafe")
        unsafeHost.proxyCommand = "cloudflared access ssh --hostname %h"
        let rejected = NSRemoteShell.configured(for: unsafeHost, timeout: 2)
        rejected.requestConnectAndWait()
        XCTAssertFalse(rejected.isConnected)
        XCTAssertEqual(rejected.getLastError(), "The server address is not a valid hostname.")
        rejected.destroyPermanently()
    }

    func testThePublicKeyIsGivenButNotThePrivateOne() async {
        let reply = await call("tools/call", ["name": "list_identities", "arguments": [:]])
        XCTAssertTrue(reply.contains(String(key.publicKey.split(separator: " ")[1])))
        assertNoSecret(reply)
    }

    func testInitializeAndListTools() async {
        let reply = await call("initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test", "version": "1"]])
        XCTAssertTrue(reply.contains("\"protocolVersion\":\"2025-06-18\""))
        XCTAssertTrue(reply.contains("tamio"))
        let tools = await call("tools/list")
        for name in ["list_hosts", "run_command", "add_host", "add_identity", "log_activity", "get_activity"] {
            XCTAssertTrue(tools.contains("\"\(name)\""), name)
        }
        let notification: JSONValue = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        let none = await AgentServer().handle(notification.encodedString(), client: AgentSession())
        XCTAssertNil(none, "notifications get no reply")
    }

    func testWritesNeedApproval() async {
        // No environment: nobody to ask, so nothing changes.
        let reply = await call("tools/call", ["name": "remove_host", "arguments": ["host": "agent-test-key"]])
        XCTAssertTrue(reply.contains("\"isError\":true"))
        XCTAssertTrue(TamioStore.shared.machineGroup.machines.contains { $0.name == "agent-test-key" })
    }

    func testTheExitCodeIsReadFromTheMarker() {
        let wrapped = AgentRunner.wrap("echo 'hi'; false", sudo: true)
        XCTAssertTrue(wrapped.hasPrefix("sudo -n sh -c 'echo '\\''hi'\\''; false'"))
        let parsed = AgentRunner.parse("hi\r\n\n__TAMIO_EXIT__1\r\n")
        XCTAssertEqual(parsed.exitCode, 1)
        XCTAssertEqual(parsed.output, "hi\n")
        XCTAssertNil(AgentRunner.parse("no marker").exitCode)
    }

    func testMetricsPrewarmsAndReadsFromEnvironment() async {
        final class MockEnvironment: AgentEnvironment {
            var prepared: [RDMachine.ID] = []
            var requested: [RDMachine.ID] = []
            func approve(_: AgentRequest) async -> Bool { false }
            func prepareMetrics(for machines: [RDMachine.ID]) { prepared = machines }
            func metrics(for machine: RDMachine.ID) async -> JSONValue? {
                requested.append(machine)
                return ["cpuPercent": .number(12.5)]
            }
            func isForwarding(_: RDPortForward.ID) -> Bool { false }
            func startForward(_: RDPortForward.ID) {}
            func stopForward(_: RDPortForward.ID) {}
        }

        let server = AgentServer()
        let env = MockEnvironment()
        server.environment = env
        let request: JSONValue = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "get_metrics", "arguments": ["hosts": ["agent-test-key", "agent-test-password"]]],
        ]
        let reply = await server.handle(request.encodedString(), client: AgentSession()) ?? ""
        XCTAssertEqual(env.prepared, machines)
        XCTAssertEqual(env.requested, machines)
        XCTAssertTrue(reply.contains("12.5"))
    }
}
