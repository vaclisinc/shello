import Foundation

public enum HostAuth: Codable, Hashable, Sendable {
    /// Password kept in the Keychain under `Keychain.passwordAccount(host:)`.
    case password
    /// A key from the key list; private material under `Keychain.privateKeyAccount(key:)`.
    case key(UUID)
}

/// A saved SSH destination. Secrets are never stored here.
public struct HostProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var auth: HostAuth
    /// Launch (or reattach) the herdr TUI as soon as the shell opens.
    public var autoAttachHerdr: Bool
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
        autoAttachHerdr: Bool = true,
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
        self.autoAttachHerdr = autoAttachHerdr
        self.herdrPath = herdrPath
        self.herdrSession = herdrSession
        self.monitorAgents = monitorAgents
    }

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
