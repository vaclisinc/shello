import Foundation

/// One entry of an agent conversation, ready to render as chat.
public enum TranscriptItem: Hashable, Sendable, Identifiable {
    /// `images` holds the raw bytes (PNG/JPEG) of images pasted into the prompt.
    case user(id: String, text: String, images: [Data])
    case assistant(id: String, text: String)
    case tool(TranscriptTool)
    /// Claude Code compacted the conversation; `summary` is what it carried forward.
    case compacted(id: String, summary: String)

    public var id: String {
        switch self {
        case .user(let id, _, _), .assistant(let id, _), .compacted(let id, _): return id
        case .tool(let tool): return tool.id
        }
    }
}

public struct TranscriptTool: Hashable, Sendable {
    public var id: String
    public var name: String
    /// The most telling input: the command, file path, pattern, URL…
    public var summary: String
    public var result: String?
    public var isError = false

    public var isPending: Bool { result == nil }
}

/// Accumulates Claude Code's `~/.claude/projects/<project>/<session>.jsonl` into chat items.
/// Feed it whole lines as they arrive; tool results are attached to the call they answer.
public struct ClaudeTranscript: Sendable {
    public private(set) var items: [TranscriptItem] = []
    private var toolIndex: [String: Int] = [:]
    /// Older items are dropped past this many so a long session stays light.
    public var limit = 400

    public init() {}

    public mutating func ingest(_ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            ingest(line: line)
        }
    }

    private mutating func ingest(line: Substring) {
        // A partial first line (from `tail`) or a non-message record simply doesn't parse.
        guard let data = line.data(using: .utf8),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.isMeta != true,
              let message = entry.message,
              entry.type == "user" || entry.type == "assistant" else { return }
        let base = entry.uuid ?? UUID().uuidString

        // The summary Claude Code injects after compacting looks like a user turn; it isn't one.
        if entry.type == "user", let summary = Self.compactSummary(entry: entry, content: message.content) {
            append(.compacted(id: base, summary: summary))
            return
        }

        switch message.content {
        case .text(let raw):
            if entry.type == "user", let text = Self.cleanUserText(raw) {
                append(.user(id: base, text: text, images: []))
            } else if entry.type == "assistant", !raw.isEmpty {
                append(.assistant(id: base, text: raw))
            }
        case .blocks(let blocks):
            var userText: [String] = []
            var images: [Data] = []
            for (offset, block) in blocks.enumerated() {
                switch block.type {
                case "text":
                    guard let text = block.text else { continue }
                    if entry.type == "assistant" {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { append(.assistant(id: "\(base)-\(offset)", text: trimmed)) }
                    } else if let cleaned = Self.cleanUserText(text) {
                        userText.append(cleaned)
                    }
                case "image":
                    if let encoded = block.source?.data, let data = Data(base64Encoded: encoded) {
                        images.append(data)
                    }
                case "tool_use":
                    guard let id = block.id else { continue }
                    let tool = TranscriptTool(id: id, name: block.name ?? "Tool", summary: Self.summary(of: block.input))
                    toolIndex[id] = items.count
                    append(.tool(tool))
                case "tool_result":
                    guard let id = block.toolUseId, let index = toolIndex[id], index < items.count,
                          case .tool(var tool) = items[index] else { continue }
                    tool.result = block.content?.plainText ?? ""
                    tool.isError = block.isError ?? false
                    items[index] = .tool(tool)
                default:
                    // `thinking` and anything new: not shown.
                    continue
                }
            }
            if !userText.isEmpty || !images.isEmpty {
                append(.user(id: base, text: userText.joined(separator: "\n\n"), images: images))
            }
        }
    }

    private mutating func append(_ item: TranscriptItem) {
        items.append(item)
        guard items.count > limit else { return }
        let drop = items.count - limit
        items.removeFirst(drop)
        toolIndex = toolIndex.compactMapValues { $0 >= drop ? $0 - drop : nil }
    }

    static let compactSummaryPrefix = "This session is being continued from a previous conversation"

    private static func compactSummary(entry: Entry, content: Content) -> String? {
        let text: String
        switch content {
        case .text(let raw): text = raw
        case .blocks(let blocks): text = blocks.compactMap(\.text).joined(separator: "\n")
        }
        guard entry.isCompactSummary == true || text.hasPrefix(compactSummaryPrefix) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops harness noise from user turns; slash commands become `/name args`.
    static func cleanUserText(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: #"(?s)<system-reminder>.*?</system-reminder>"#, with: "", options: .regularExpression)
        if let name = firstMatch(#"<command-name>(.*?)</command-name>"#, in: text) {
            let args = firstMatch(#"(?s)<command-args>(.*?)</command-args>"#, in: text) ?? ""
            let command = name.hasPrefix("/") ? name : "/" + name
            return args.isEmpty ? command : "\(command) \(args)"
        }
        if text.contains("<local-command-stdout>") || text.contains("<local-command-caveat>") { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summary(of input: [String: JSONValue]?) -> String {
        guard let input else { return "" }
        for key in ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt", "skill"] {
            if let value = input[key]?.plainText, !value.isEmpty { return value }
        }
        return input.values.lazy.compactMap { $0.plainText }.first { !$0.isEmpty } ?? ""
    }

    // MARK: Decoding

    private struct Entry: Decodable {
        var type: String?
        var uuid: String?
        var isMeta: Bool?
        var isCompactSummary: Bool?
        var message: Message?
    }

    private struct Message: Decodable {
        var content: Content
    }

    private enum Content: Decodable {
        case text(String)
        case blocks([Block])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks((try? container.decode([Block].self)) ?? [])
            }
        }
    }

    private struct Block: Decodable {
        var type: String
        var text: String?
        var id: String?
        var name: String?
        var input: [String: JSONValue]?
        var toolUseId: String?
        var content: JSONValue?
        var isError: Bool?
        var source: ImageSource?

        struct ImageSource: Decodable {
            var data: String?
        }

        enum CodingKeys: String, CodingKey {
            case type, text, id, name, input, content, source
            case toolUseId = "tool_use_id"
            case isError = "is_error"
        }
    }
}

/// Loosely typed JSON for tool inputs and results.
public indirect enum JSONValue: Decodable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object((try? c.decode([String: JSONValue].self)) ?? [:]) }
    }

    /// Text content: strings as-is, `[{type: text, text}]` joined, numbers/bools printed.
    public var plainText: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        case .array(let values):
            let parts = values.compactMap { value -> String? in
                if case .object(let o) = value {
                    if o["type"]?.plainText == "image" { return "[image]" }
                    return o["text"]?.plainText
                }
                return value.plainText
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        case .object(let o): return o["text"]?.plainText
        case .null: return nil
        }
    }
}

/// Where an agent's session info points, as reported by herdr integrations.
/// herdr 0.9 reports `{kind, value}`; older releases may send `session_id` / `session_path`.
public struct AgentSessionInfo: Codable, Hashable, Sendable {
    public var source: String?
    public var agent: String?
    public var kind: String?
    public var value: String?
    public var sessionId: String?
    public var sessionPath: String?
    public var agentSessionId: String?
    public var agentSessionPath: String?

    public init(kind: String? = nil, value: String? = nil, sessionId: String? = nil, sessionPath: String? = nil) {
        self.kind = kind
        self.value = value
        self.sessionId = sessionId
        self.sessionPath = sessionPath
    }

    /// Absolute transcript path, when reported.
    public var path: String? {
        if let path = sessionPath ?? agentSessionPath, !path.isEmpty { return path }
        if kind?.contains("path") == true, let value, !value.isEmpty { return value }
        return nil
    }

    /// Session id, when reported.
    public var id: String? {
        if let id = sessionId ?? agentSessionId, !id.isEmpty { return id }
        if kind?.contains("path") != true, let value, !value.isEmpty { return value }
        return nil
    }

    public var isKnown: Bool { path != nil || id != nil }
}

/// Reads the tail of an agent's transcript over SSH, then only what was appended since.
public enum TranscriptFetch {
    /// Bytes of history pulled on the first read.
    public static let initialBytes = 600_000

    /// Claude Code's project directory name for a working directory: every
    /// character other than a letter, digit or `-` becomes `-`.
    public static func claudeProjectDirectory(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" })
    }

    /// Shell script printing `path`, `size`, `full|inc`, then transcript bytes.
    /// `known` is the file and byte offset already read, for incremental reads.
    ///
    /// The transcript is located, most exact first, by: the session a herdr integration
    /// reported; the pane's process (`processInfo` is a command printing
    /// `herdr pane process-info` JSON) matched to Claude Code's `~/.claude/sessions/<pid>.json`;
    /// and, only when `allowFolderGuess`, the newest transcript for the working directory.
    public static func command(
        session: AgentSessionInfo?,
        processInfo: String? = nil,
        cwd: String?,
        allowFolderGuess: Bool = true,
        known: (path: String, size: Int)?
    ) -> String? {
        var steps: [String] = []
        if let path = session?.path {
            steps.append("f=\(shellQuote(path))")
        } else if let id = session?.id, id.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil {
            steps.append(#"f=$(ls -t "$HOME"/.claude/projects/*/\#(id).jsonl 2>/dev/null | head -1)"#)
        }
        if let processInfo {
            // Every pid in the pane's foreground process group, the group leader first.
            steps.append(#"""
            [ -n "$f" ] || { info=$(\#(processInfo) 2>/dev/null); for p in $(printf '%s' "$info" | grep -o '"foreground_process_group_id":[0-9]*' | grep -o '[0-9]*$') $(printf '%s' "$info" | grep -o '"pid":[0-9]*' | grep -o '[0-9]*$'); do s="$HOME/.claude/sessions/$p.json"; [ -f "$s" ] || continue; id=$(grep -o '"sessionId":"[A-Za-z0-9-]*"' "$s" | head -1 | cut -d'"' -f4); [ -n "$id" ] && f=$(ls -t "$HOME"/.claude/projects/*/"$id".jsonl 2>/dev/null | head -1); [ -n "$f" ] && break; done; }
            """#)
        }
        if allowFolderGuess, let cwd, !cwd.isEmpty {
            let dir = claudeProjectDirectory(for: cwd)
            steps.append(#"[ -n "$f" ] || f=$(ls -t "$HOME"/.claude/projects/\#(dir)/*.jsonl 2>/dev/null | head -1)"#)
        }
        guard !steps.isEmpty else { return nil }
        let locate = "f=; " + steps.joined(separator: "; ")
        var script = locate + #"; [ -n "$f" ] && [ -f "$f" ] || exit 3; s=$(wc -c < "$f" | tr -d ' '); echo "$f"; echo "$s"; "#
        if let known {
            script += #"if [ "$f" = \#(shellQuote(known.path)) ] && [ "$s" -ge \#(known.size) ]; then echo inc; tail -c +\#(known.size + 1) "$f" | head -c $((s - \#(known.size))); else echo full; tail -c \#(initialBytes) "$f"; fi"#
        } else {
            script += #"echo full; tail -c \#(initialBytes) "$f""#
        }
        return script
    }

    public struct Chunk: Equatable, Sendable {
        public var path: String
        /// Byte offset up to which the file has been consumed (complete lines only).
        public var consumed: Int
        public var isIncremental: Bool
        /// Complete JSONL lines.
        public var body: String
    }

    /// Parses `command(...)` output. Only complete lines are kept; a trailing partial
    /// line is left for the next read by not counting its bytes as consumed.
    public static func parse(_ output: String) -> Chunk? {
        let parts = output.split(separator: "\n", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3, let size = Int(parts[1]) else { return nil }
        let path = String(parts[0])
        let incremental = parts[2] == "inc"
        let raw = parts.count > 3 ? String(parts[3]) : ""
        guard let lastNewline = raw.lastIndex(of: "\n") else {
            // Nothing complete yet: consume nothing new.
            return Chunk(path: path, consumed: size - raw.utf8.count, isIncremental: incremental, body: "")
        }
        let complete = String(raw[...lastNewline])
        let pending = raw.utf8.count - complete.utf8.count
        return Chunk(path: path, consumed: size - pending, isIncremental: incremental, body: complete)
    }
}
