import Foundation

/// POSIX single-quote escaping, safe for sh/bash/zsh (and fish 3+).
public func shellQuote(_ value: String) -> String {
    if !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=+@%,".contains($0) }) {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Where `herdr agent read` / `pane read` pulls text from.
public enum HerdrReadSource: String, Sendable, CaseIterable {
    case visible
    case recent
    case recentUnwrapped = "recent-unwrapped"
}

/// Builds the shell command lines this app runs over SSH exec channels.
///
/// Exec channels don't source interactive shell rc files, so a default install
/// in `~/.local/bin` or Homebrew is often missing from PATH. We prepend the
/// usual install locations unless the user configured an absolute path.
public struct HerdrCommand: Sendable, Hashable {
    public var executable: String
    /// Named herdr session (`herdr --session <name>`); nil uses the default session.
    public var session: String?

    public static let extraPath = [
        "$HOME/.local/bin",
        "$HOME/.cargo/bin",
        "$HOME/.nix-profile/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    public init(executable: String = "herdr", session: String? = nil) {
        let trimmed = executable.trimmingCharacters(in: .whitespaces)
        self.executable = trimmed.isEmpty ? "herdr" : trimmed
        let s = session?.trimmingCharacters(in: .whitespaces)
        self.session = (s?.isEmpty ?? true) ? nil : s
    }

    /// `herdr [--session X] <args...>` with PATH fix-up, ready for an exec channel.
    public func cli(_ args: [String]) -> String {
        var parts = [quotedExecutable]
        if let session { parts += ["--session", shellQuote(session)] }
        parts += args.map(shellQuote)
        let line = parts.joined(separator: " ")
        if executable.hasPrefix("/") || executable.hasPrefix("~") { return line }
        return "PATH=\"\(Self.extraPath.joined(separator: ":")):$PATH\" \(line)"
    }

    /// Keeps `~/` expandable while quoting the rest of a configured path.
    var quotedExecutable: String {
        if executable.hasPrefix("~/") {
            return "\"$HOME\"/" + shellQuote(String(executable.dropFirst(2)))
        }
        return shellQuote(executable)
    }

    /// Typed into the interactive shell to launch or reattach the herdr TUI.
    public func attach() -> String {
        cli([])
    }

    public func snapshot() -> String { cli(["api", "snapshot"]) }

    public func status() -> String { cli(["status"]) }

    public func agentRead(_ target: String, lines: Int = 200, source: HerdrReadSource = .recentUnwrapped) -> String {
        cli(["agent", "read", target, "--source", source.rawValue, "--lines", String(lines)])
    }

    /// Submits text + Enter to an agent. herdr rejects this with `agent_blocked`
    /// while the agent shows an approval dialog; use `agentSendKeys` for that.
    public func agentPrompt(_ target: String, text: String) -> String {
        cli(["agent", "prompt", target, text])
    }

    /// Logical keys such as `enter`, `esc`, `ctrl+c`, `up`, `1`.
    public func agentSendKeys(_ target: String, keys: [String]) -> String {
        cli(["agent", "send-keys", target] + keys)
    }

    public func agentFocus(_ target: String) -> String {
        cli(["agent", "focus", target])
    }

    public func paneRead(_ paneId: String, lines: Int = 200, source: HerdrReadSource = .recentUnwrapped) -> String {
        cli(["pane", "read", paneId, "--source", source.rawValue, "--lines", String(lines)])
    }

    public func paneSendKeys(_ paneId: String, keys: [String]) -> String {
        cli(["pane", "send-keys", paneId] + keys)
    }

    /// Types text into a pane without pressing Enter.
    public func paneSendText(_ paneId: String, text: String) -> String {
        cli(["pane", "send-text", paneId, text])
    }

    public func paneRun(_ paneId: String, command: String) -> String {
        cli(["pane", "run", paneId, command])
    }

    public func paneFocus(_ paneId: String) -> String {
        cli(["pane", "focus", paneId])
    }
}

/// Error body herdr prints (as JSON on stderr) when a request fails.
public struct HerdrAPIError: Error, Decodable, Sendable, Equatable, LocalizedError {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { "\(message) (\(code))" }
}

public enum HerdrResponseError: Error, LocalizedError, Equatable {
    case herdrNotFound
    case serverNotRunning(String)
    case unexpectedOutput(String)

    public var errorDescription: String? {
        switch self {
        case .herdrNotFound:
            return "herdr was not found on the remote host. Install it or set its path in the host settings."
        case .serverNotRunning(let detail):
            return "No herdr server is running. Open the terminal and start `herdr` first.\n\(detail)"
        case .unexpectedOutput(let text):
            return "Unexpected output from herdr:\n\(text.prefix(400))"
        }
    }
}

public enum HerdrResponse {
    private struct Envelope<Result: Decodable>: Decodable {
        var result: Result?
        var error: HerdrAPIError?
    }

    private struct SnapshotResult: Decodable {
        var type: String
        var snapshot: SessionSnapshot
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// Returns the JSON object in `text`, skipping anything a noisy login shell printed before it.
    static func jsonSlice(_ text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return Data(text[start...end].utf8)
    }

    public static func decodeSnapshot(_ text: String) throws -> SessionSnapshot {
        guard let data = jsonSlice(text) else { throw HerdrResponseError.unexpectedOutput(text) }
        let envelope = try decoder().decode(Envelope<SnapshotResult>.self, from: data)
        if let error = envelope.error { throw error }
        guard let result = envelope.result else { throw HerdrResponseError.unexpectedOutput(text) }
        return result.snapshot
    }

    /// Maps a failed command's stderr/exit status to a useful error.
    public static func failure(exitCode: Int, stdout: String, stderr: String) -> Error {
        let combined = stderr.isEmpty ? stdout : stderr
        if exitCode == 127 || combined.contains("command not found") {
            return HerdrResponseError.herdrNotFound
        }
        if let data = jsonSlice(combined),
           let envelope = try? decoder().decode(Envelope<IgnoredResult>.self, from: data),
           let error = envelope.error {
            return error
        }
        let lower = combined.lowercased()
        if lower.contains("not running") || lower.contains("connection refused") || lower.contains("no such socket") {
            return HerdrResponseError.serverNotRunning(combined.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return HerdrResponseError.unexpectedOutput(combined.isEmpty ? "exit status \(exitCode)" : combined)
    }

    private struct IgnoredResult: Decodable {}
}
