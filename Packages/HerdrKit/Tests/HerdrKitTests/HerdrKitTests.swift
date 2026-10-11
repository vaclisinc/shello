import XCTest
@testable import HerdrKit

final class HerdrKitTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Snapshot decoding

    func testDecodesSnapshot() throws {
        let snapshot = try HerdrResponse.decodeSnapshot(try fixture("snapshot.json"))
        XCTAssertEqual(snapshot.version, "0.9.3")
        XCTAssertEqual(snapshot.protocol, 7)
        XCTAssertEqual(snapshot.workspaces.first?.label, "api")
        XCTAssertEqual(snapshot.panes.count, 3)
        XCTAssertEqual(snapshot.agents.count, 3)
        XCTAssertEqual(snapshot.blockedCount, 1)

        let reviewer = try XCTUnwrap(snapshot.agents.first { $0.name == "reviewer" })
        XCTAssertEqual(reviewer.agentStatus, .blocked)
        XCTAssertEqual(reviewer.target, "reviewer")
        XCTAssertEqual(reviewer.kindLabel, "Claude Code")
        XCTAssertEqual(reviewer.subtitle, "Allow edit to src/main.rs?")

        let unnamed = try XCTUnwrap(snapshot.agents.first { $0.paneId == "w1:p2" })
        XCTAssertEqual(unnamed.target, "w1:p2", "unnamed agents are targeted by pane id")
    }

    func testUnknownStatusFallsBack() throws {
        let snapshot = try HerdrResponse.decodeSnapshot(try fixture("snapshot.json"))
        XCTAssertEqual(snapshot.agents.first { $0.paneId == "w1:p9" }?.agentStatus, .unknown)
    }

    func testAgentsByUrgency() throws {
        let snapshot = try HerdrResponse.decodeSnapshot(try fixture("snapshot.json"))
        XCTAssertEqual(snapshot.agentsByUrgency.map(\.agentStatus), [.blocked, .working, .unknown])
    }

    func testSnapshotIgnoresShellNoise() throws {
        let noisy = "Welcome to Ubuntu\n" + (try fixture("snapshot.json")) + "\n"
        XCTAssertEqual(try HerdrResponse.decodeSnapshot(noisy).agents.count, 3)
    }

    func testErrorEnvelope() {
        let stderr = #"{"id":"cli:api:snapshot","error":{"code":"server_not_running","message":"no herdr server is running at /tmp/x.sock; run `herdr` to start or attach it"}}"#
        let error = HerdrResponse.failure(exitCode: 1, stdout: "", stderr: stderr)
        XCTAssertEqual((error as? HerdrAPIError)?.code, "server_not_running")
    }

    func testHerdrNotFound() {
        let error = HerdrResponse.failure(exitCode: 127, stdout: "", stderr: "sh: herdr: command not found")
        XCTAssertEqual(error as? HerdrResponseError, .herdrNotFound)
    }

    // MARK: Command building

    func testShellQuote() {
        XCTAssertEqual(shellQuote("w1:p2"), "w1:p2")
        XCTAssertEqual(shellQuote("hello world"), "'hello world'")
        XCTAssertEqual(shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(shellQuote("$(rm -rf ~)"), "'$(rm -rf ~)'")
        XCTAssertEqual(shellQuote(""), "''")
    }

    func testCommandAddsPathForBareExecutable() {
        let cmd = HerdrCommand().snapshot()
        XCTAssertTrue(cmd.hasPrefix("PATH=\"$HOME/.local/bin:"))
        XCTAssertTrue(cmd.hasSuffix(":$PATH\" herdr api snapshot"))
    }

    func testCommandWithAbsolutePathAndSession() {
        let cmd = HerdrCommand(executable: "/opt/herdr/bin/herdr", session: "work").agentPrompt("reviewer", text: "Fix the bug's root cause")
        XCTAssertEqual(cmd, #"/opt/herdr/bin/herdr --session work agent prompt reviewer 'Fix the bug'\''s root cause'"#)
    }

    func testTildeExecutableStaysExpandable() {
        let cmd = HerdrCommand(executable: "~/bin/herdr").status()
        XCTAssertEqual(cmd, #""$HOME"/bin/herdr status"#)
    }

    func testBlankSessionIsIgnored() {
        XCTAssertNil(HerdrCommand(session: "  ").session)
        XCTAssertEqual(HerdrCommand(executable: "  ").executable, "herdr")
    }

    func testSendKeysAndRead() {
        let herdr = HerdrCommand(executable: "/usr/bin/herdr")
        XCTAssertEqual(herdr.agentSendKeys("w1:p1", keys: ["ctrl+c", "enter"]), "/usr/bin/herdr agent send-keys w1:p1 ctrl+c enter")
        XCTAssertEqual(herdr.agentRead("reviewer", lines: 50), "/usr/bin/herdr agent read reviewer --source recent-unwrapped --lines 50")
    }

    // MARK: Transitions

    private func agent(_ id: String, _ status: AgentStatus) -> AgentInfo {
        AgentInfo(
            terminalId: id, name: nil, agent: "claude", title: nil, terminalTitleStripped: nil,
            displayAgent: nil, agentStatus: status, workspaceId: "w1", tabId: "w1:t1",
            paneId: "w1:\(id)", focused: false, stateChangeSeq: nil, completionSeq: nil, cwd: nil, foregroundCwd: nil
        )
    }

    func testTransitions() {
        let before = SessionSnapshot(agents: [agent("a", .working), agent("b", .idle), agent("c", .working)])
        let after = SessionSnapshot(agents: [agent("a", .blocked), agent("b", .working), agent("c", .done), agent("d", .blocked)])
        let alerts = AgentTransitions.alerts(from: before, to: after)
        XCTAssertEqual(alerts.map(\.kind), [.needsInput, .finished])
        XCTAssertEqual(alerts.map(\.agent.terminalId), ["a", "c"])
    }

    func testNoAlertsOnFirstSnapshot() {
        XCTAssertTrue(AgentTransitions.alerts(from: nil, to: SessionSnapshot(agents: [agent("a", .blocked)])).isEmpty)
    }

    // MARK: Keys

    func testGeneratedKeyHasOpenSSHPublicKey() throws {
        let (info, secret) = SSHKeyFactory.generateEd25519(name: "my phone")
        XCTAssertTrue(info.publicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
        XCTAssertTrue(info.publicKey.hasSuffix(" my-phone"))
        XCTAssertTrue(info.fingerprint.hasPrefix("SHA256:"))
        guard case .ed25519Seed(let seed) = secret else { return XCTFail("expected seed") }
        XCTAssertEqual(seed.count, 32)
        XCTAssertNoThrow(try SSHKeyFactory.authenticationMethod(username: "me", key: secret))
    }

    func testImportsOpenSSHEd25519() throws {
        let (info, _) = try SSHKeyFactory.importOpenSSH(name: "laptop", pem: try fixture("test_ed25519"), passphrase: nil)
        let expected = try fixture("test_ed25519.pub").split(separator: " ")[1]
        XCTAssertEqual(info.keyType, "ssh-ed25519")
        XCTAssertEqual(info.publicKey.split(separator: " ")[1], expected)
        XCTAssertEqual(info.fingerprint, "SHA256:Zsfs4IJPm9rXc2w/4ebOxhjoXMy63EnDZPQxgDGOhXA")
    }

    func testImportsOpenSSHRSA() throws {
        let (info, _) = try SSHKeyFactory.importOpenSSH(name: "old", pem: try fixture("test_rsa"), passphrase: nil)
        XCTAssertEqual(info.keyType, "ssh-rsa")
        XCTAssertEqual(info.fingerprint, "SHA256:YiTmXcsybuKyviYC+SlINP+4wZ73yhSg/tDkkKrRTF0")
    }

    func testRejectsNonOpenSSHKey() {
        XCTAssertThrowsError(try SSHKeyFactory.importOpenSSH(name: "x", pem: "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----", passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyError, .notOpenSSHFormat)
        }
    }

    func testHostProfileKnownHostsKey() {
        XCTAssertEqual(HostProfile(hostname: "Box.local", port: 22, username: "me").knownHostsKey, "box.local")
        XCTAssertEqual(HostProfile(hostname: "box", port: 2222, username: "me").knownHostsKey, "[box]:2222")
    }
}
