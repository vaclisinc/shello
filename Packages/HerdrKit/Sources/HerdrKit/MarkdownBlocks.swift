import Foundation

/// Block-level Markdown, as agents write it. Inline styling (bold, `code`, links)
/// stays in the text and is rendered by the UI.
public enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// `marker` is "•" for bullets or "3." for numbered items; `depth` counts indent levels.
    case listItem(marker: String, depth: Int, text: String)
    case quote(String)
    case code(language: String, text: String)
    case rule
}

public enum MarkdownParser {
    public static func blocks(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.popFirst() {
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    code.append(next)
                }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    lines.removeFirst()
                    quoted.append(String(next.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // A continuation line of the previous list item (indented, not a new marker).
            if paragraph.isEmpty, line.hasPrefix("  "), case .listItem(let marker, let depth, let text)? = blocks.last {
                blocks[blocks.count - 1] = .listItem(marker: marker, depth: depth, text: text + "\n" + trimmed)
                continue
            }

            paragraph.append(line)
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        let rest = line.dropFirst(indent.count)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return .listItem(marker: "•", depth: depth, text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " {
                return .listItem(marker: "\(digits).", depth: depth, text: after.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
