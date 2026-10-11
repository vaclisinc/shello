import Foundation

public enum HostAuth: Codable, Hashable, Sendable {
    /// Password kept in the Keychain under `Keychain.passwordAccount(host:)`.
    case password
    /// A key from the key list; private material under `Keychain.privateKeyAccount(key:)`.
    case key(UUID)
}

/// What the app types into the shell once it opens.
public enum StartupMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Launch or reattach the herdr TUI; enables the Agents inbox.
    case herdr
    /// `tmux new-session -A`: attach to the named session, creating it if needed.
    case tmux
    /// A plain login shell.
    case shell
    /// Any command, e.g. `zellij attach -c` or `screen -xRR`.
    case custom
}

/// A saved SSH destination. Secrets are never stored here.
public struct HostProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var auth: HostAuth
    public var startup: StartupMode
    /// tmux session to attach or create when `startup == .tmux`.
    public var tmuxSession: String
    /// Command typed into the shell when `startup == .custom`.
    public var customCommand: String
    /// `herdr` binary name or absolute path on the remote machine.
    public var herdrPath: String
    /// Optional named herdr session (`herdr --session <name>`).
    public var herdrSession: String
    /// Poll herdr for agent state and alert on blocked/finished agents.
    public var monitorAgents: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        auth: HostAuth = .password,
        startup: StartupMode = .herdr,
        tmuxSession: String = "main",
        customCommand: String = "",
        herdrPath: String = "herdr",
        herdrSession: String = "",
        monitorAgents: Bool = true
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
        self.startup = startup
        self.tmuxSession = tmuxSession
        self.customCommand = customCommand
        self.herdrPath = herdrPath
        self.herdrSession = herdrSession
        self.monitorAgents = monitorAgents
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, hostname, port, username, auth, startup, tmuxSession, customCommand
        case herdrPath, herdrSession, monitorAgents
        /// Before startup modes existed: true meant `.herdr`, false a plain shell.
        case autoAttachHerdr
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        auth = try c.decode(HostAuth.self, forKey: .auth)
        if let startup = try c.decodeIfPresent(StartupMode.self, forKey: .startup) {
            self.startup = startup
        } else {
            startup = try c.decodeIfPresent(Bool.self, forKey: .autoAttachHerdr) == false ? .shell : .herdr
        }
        tmuxSession = try c.decodeIfPresent(String.self, forKey: .tmuxSession) ?? "main"
        customCommand = try c.decodeIfPresent(String.self, forKey: .customCommand) ?? ""
        herdrPath = try c.decodeIfPresent(String.self, forKey: .herdrPath) ?? "herdr"
        herdrSession = try c.decodeIfPresent(String.self, forKey: .herdrSession) ?? ""
        monitorAgents = try c.decodeIfPresent(Bool.self, forKey: .monitorAgents) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(hostname, forKey: .hostname)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(auth, forKey: .auth)
        try c.encode(startup, forKey: .startup)
        try c.encode(tmuxSession, forKey: .tmuxSession)
        try c.encode(customCommand, forKey: .customCommand)
        try c.encode(herdrPath, forKey: .herdrPath)
        try c.encode(herdrSession, forKey: .herdrSession)
        try c.encode(monitorAgents, forKey: .monitorAgents)
    }

    /// The line typed into the shell after connecting, or nil for a plain shell.
    public var startupCommand: String? {
        switch startup {
        case .herdr:
            return herdr.attach()
        case .tmux:
            let session = tmuxSession.trimmingCharacters(in: .whitespaces)
            return "tmux new-session -A -s \(shellQuote(session.isEmpty ? "main" : session))"
        case .shell:
            return nil
        case .custom:
            let command = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        }
    }

    /// Agent polling only makes sense when this host runs herdr.
    public var watchesAgents: Bool { startup == .herdr && monitorAgents }

    public var displayName: String { name.isEmpty ? hostname : name }

    public var addressLabel: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }

    /// Identity used in the known-hosts store, like OpenSSH's `[host]:port`.
    public var knownHostsKey: String {
        port == 22 ? hostname.lowercased() : "[\(hostname.lowercased())]:\(port)"
    }

    public var herdr: HerdrCommand {
        HerdrCommand(executable: herdrPath, session: herdrSession)
    }

    public var isValid: Bool {
        !hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(port)
    }
}
