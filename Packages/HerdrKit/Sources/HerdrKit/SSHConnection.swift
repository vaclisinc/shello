import Citadel
import Foundation
import NIOCore
import NIOSSH

public struct CommandResult: Sendable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { exitCode == 0 }
}

public enum SSHConnectionError: Error, LocalizedError {
    case missingSecret
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .missingSecret: return "No password or key is saved for this host."
        case .timedOut: return "The command timed out."
        }
    }
}

/// One authenticated SSH connection. Exec channels (herdr API calls) and the
/// interactive PTY are multiplexed over it.
public final class SSHConnection: @unchecked Sendable {
    public let profile: HostProfile
    public let client: SSHClient

    private let lock = NSLock()
    private var _herdrLegacyCLI: Bool?

    /// Set once we learn the host runs a herdr without `herdr api` (0.7.x); nil until the first snapshot.
    public var herdrLegacyCLI: Bool? {
        get { lock.withLock { _herdrLegacyCLI } }
        set { lock.withLock { _herdrLegacyCLI = newValue } }
    }

    private init(profile: HostProfile, client: SSHClient) {
        self.profile = profile
        self.client = client
    }

    public static func connect(
        profile: HostProfile,
        keychain: Keychain = Keychain(),
        knownHosts: KnownHostsStore,
        confirmHostKey: @escaping TOFUHostKeyValidator.Confirm
    ) async throws -> SSHConnection {
        let auth: SSHAuthenticationMethod
        let username = profile.username.trimmingCharacters(in: .whitespaces)
        switch profile.auth {
        case .password:
            guard let password = try keychain.string(for: Keychain.passwordAccount(host: profile.id)) else {
                throw SSHConnectionError.missingSecret
            }
            auth = .passwordBased(username: username, password: password)
        case .key(let keyID):
            guard let stored = try keychain.codable(StoredPrivateKey.self, for: Keychain.privateKeyAccount(key: keyID)) else {
                throw SSHConnectionError.missingSecret
            }
            auth = try SSHKeyFactory.authenticationMethod(username: username, key: stored)
        }

        let validator = TOFUHostKeyValidator(host: profile.knownHostsKey, store: knownHosts, confirm: confirmHostKey)
        let client = try await SSHClient.connect(
            host: profile.hostname.trimmingCharacters(in: .whitespaces),
            port: profile.port,
            authenticationMethod: auth,
            hostKeyValidator: .custom(validator),
            reconnect: .never,
            connectTimeout: .seconds(15)
        )
        return SSHConnection(profile: profile, client: client)
    }

    public var isConnected: Bool { client.isConnected }

    public func onDisconnect(_ handler: @escaping @Sendable () -> Void) {
        client.onDisconnect(perform: handler)
    }

    /// Runs a command on a fresh exec channel, collecting both streams and the exit code.
    public func run(_ command: String, timeout: Duration = .seconds(30)) async throws -> CommandResult {
        try await withThrowingTaskGroup(of: CommandResult.self) { group in
            group.addTask {
                let stream = try await self.client.executeCommandStream(command)
                var stdout = ByteBuffer()
                var stderr = ByteBuffer()
                var exitCode = 0
                do {
                    for try await chunk in stream {
                        switch chunk {
                        case .stdout(var buffer): stdout.writeBuffer(&buffer)
                        case .stderr(var buffer): stderr.writeBuffer(&buffer)
                        }
                    }
                } catch let failed as SSHClient.CommandFailed {
                    exitCode = failed.exitCode
                }
                return CommandResult(
                    exitCode: exitCode,
                    stdout: String(buffer: stdout),
                    stderr: String(buffer: stderr)
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SSHConnectionError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Opens an interactive login shell on a PTY. Returns when the shell exits or the channel closes.
    public func withShell(
        cols: Int,
        rows: Int,
        term: String = "xterm-256color",
        perform: (_ output: ShellOutput, _ input: ShellInput) async throws -> Void
    ) async throws {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await client.withPTY(request) { output, writer in
            try await perform(ShellOutput(base: output), ShellInput(writer: writer))
        }
    }

    public func close() async {
        try? await client.close()
    }
}

/// Bytes coming from the remote PTY (stdout and stderr interleaved, as a terminal shows them).
public struct ShellOutput: AsyncSequence {
    public typealias Element = [UInt8]
    let base: TTYOutput

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: TTYOutput.AsyncIterator

        public mutating func next() async throws -> [UInt8]? {
            guard let chunk = try await base.next() else { return nil }
            switch chunk {
            case .stdout(let buffer), .stderr(let buffer):
                return Array(buffer.readableBytesView)
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}

/// Keystrokes and window-size changes going to the remote PTY.
public struct ShellInput: @unchecked Sendable {
    let writer: TTYStdinWriter

    public func write(_ bytes: [UInt8]) async throws {
        try await writer.write(ByteBuffer(bytes: bytes))
    }

    public func resize(cols: Int, rows: Int) async throws {
        try await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }
}

/// herdr API calls over an `SSHConnection`.
public struct HerdrRemote: Sendable {
    public let connection: SSHConnection
    public var command: HerdrCommand

    public init(connection: SSHConnection) {
        self.connection = connection
        self.command = connection.profile.herdr
    }

    @discardableResult
    func checked(_ line: String, timeout: Duration = .seconds(30)) async throws -> String {
        let result = try await connection.run(line, timeout: timeout)
        guard result.succeeded else {
            throw HerdrResponse.failure(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        }
        return result.stdout
    }

    private var isLegacy: Bool { connection.herdrLegacyCLI == true }

    /// Uses `herdr api snapshot`, falling back to the per-object lists older herdr releases offer.
    public func snapshot() async throws -> SessionSnapshot {
        if !isLegacy {
            do {
                let snapshot = try HerdrResponse.decodeSnapshot(try await checked(command.snapshot(), timeout: .seconds(15)))
                connection.herdrLegacyCLI = false
                return snapshot
            } catch HerdrResponseError.unexpectedOutput(let text) where HerdrResponse.isUnknownCommand(text) {
                connection.herdrLegacyCLI = true
            }
        }
        return try HerdrResponse.decodeLegacySnapshot(try await checked(command.legacySnapshot(), timeout: .seconds(15)))
    }

    public func readAgent(_ agent: AgentInfo, lines: Int = 200, source: HerdrReadSource = .recentUnwrapped, ansi: Bool = false) async throws -> String {
        HerdrResponse.readText(try await checked(command.agentRead(agent.target, lines: lines, source: source, ansi: ansi)))
    }

    public func prompt(_ agent: AgentInfo, text: String) async throws {
        if isLegacy {
            try await checked(command.legacyAgentPrompt(agent.target, paneId: agent.paneId, text: text))
        } else {
            try await checked(command.agentPrompt(agent.target, text: text))
        }
    }

    public func sendKeys(_ agent: AgentInfo, keys: [String]) async throws {
        if isLegacy {
            try await checked(command.paneSendKeys(agent.paneId, keys: keys))
        } else {
            try await checked(command.agentSendKeys(agent.target, keys: keys))
        }
    }

    /// Types into the agent's pane without submitting, e.g. to answer a question dialog.
    public func type(_ agent: AgentInfo, text: String) async throws {
        try await checked(command.paneSendText(agent.paneId, text: text))
    }

    public func focus(_ agent: AgentInfo) async throws {
        try await checked(command.agentFocus(agent.target))
    }
}
