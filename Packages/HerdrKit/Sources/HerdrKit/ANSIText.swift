import Foundation

/// A color from an SGR escape: one of the 256 palette entries or 24-bit RGB.
public enum TerminalColor: Hashable, Sendable {
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct ANSIStyle: Hashable, Sendable {
    public var foreground: TerminalColor?
    public var background: TerminalColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false

    public init() {}
}

public struct ANSISpan: Hashable, Sendable {
    public var text: String
    public var style: ANSIStyle

    public init(text: String, style: ANSIStyle = ANSIStyle()) {
        self.text = text
        self.style = style
    }
}

/// Turns `herdr agent read --format ansi` output into styled spans.
/// Only SGR (`ESC [ … m`) is interpreted; other escape sequences are dropped.
public enum ANSIParser {
    /// Styled spans grouped by line, with invisible trailing blanks removed.
    public static func lines(_ text: String) -> [[ANSISpan]] {
        var lines: [[ANSISpan]] = [[]]
        for span in parse(text) {
            let parts = span.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                if index > 0 { lines.append([]) }
                if !part.isEmpty { lines[lines.count - 1].append(ANSISpan(text: String(part), style: span.style)) }
            }
        }
        return lines.map(trimTrailingBlanks)
    }

    public static func parse(_ text: String) -> [ANSISpan] {
        var spans: [ANSISpan] = []
        var style = ANSIStyle()
        var current = ""
        let scalars = Array(text.unicodeScalars)
        var i = 0

        func flush() {
            guard !current.isEmpty else { return }
            if let last = spans.last, last.style == style {
                spans[spans.count - 1].text += current
            } else {
                spans.append(ANSISpan(text: current, style: style))
            }
            current = ""
        }

        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "\u{1B}", i + 1 < scalars.count {
                let kind = scalars[i + 1]
                if kind == "[" {
                    // CSI: parameters, then a final byte in 0x40...0x7E.
                    var j = i + 2
                    while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) { j += 1 }
                    if j < scalars.count, scalars[j] == "m" {
                        flush()
                        let params = String(String.UnicodeScalarView(scalars[(i + 2)..<j]))
                        apply(params, to: &style)
                    }
                    i = j + 1
                } else if kind == "]" {
                    // OSC: runs until BEL or ESC \.
                    var j = i + 2
                    while j < scalars.count, scalars[j] != "\u{07}", !(scalars[j] == "\u{1B}" && j + 1 < scalars.count && scalars[j + 1] == "\\") { j += 1 }
                    i = j < scalars.count && scalars[j] == "\u{07}" ? j + 1 : j + 2
                } else {
                    i += 2
                }
                continue
            }
            if scalar != "\r" {
                current.unicodeScalars.append(scalar)
            }
            i += 1
        }
        flush()
        return spans
    }

    static func apply(_ params: String, to style: inout ANSIStyle) {
        let codes = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var k = 0
        while k < codes.count {
            let code = codes[k]
            switch code {
            case 0: style = ANSIStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.foreground = .indexed(UInt8(code - 30))
            case 39: style.foreground = nil
            case 40...47: style.background = .indexed(UInt8(code - 40))
            case 49: style.background = nil
            case 90...97: style.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: style.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                var color: TerminalColor?
                if k + 2 < codes.count, codes[k + 1] == 5 {
                    color = .indexed(UInt8(clamping: codes[k + 2]))
                    k += 2
                } else if k + 4 < codes.count, codes[k + 1] == 2 {
                    color = .rgb(UInt8(clamping: codes[k + 2]), UInt8(clamping: codes[k + 3]), UInt8(clamping: codes[k + 4]))
                    k += 4
                }
                if code == 38 { style.foreground = color } else { style.background = color }
            default: break
            }
            k += 1
        }
    }

    /// Drops trailing spaces that have no visible background, so lines aren't padded to the pane width.
    static func trimTrailingBlanks(_ line: [ANSISpan]) -> [ANSISpan] {
        var line = line
        while let last = line.last, last.style.background == nil, !last.style.inverse {
            let trimmed = String(last.text.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
            if trimmed.isEmpty {
                line.removeLast()
            } else {
                line[line.count - 1].text = trimmed
                break
            }
        }
        return line
    }

    /// Terminal columns `text` occupies: East Asian wide characters and emoji take two.
    public static func displayColumns<S: StringProtocol>(_ text: S) -> Int {
        text.reduce(0) { total, character in
            guard let scalar = character.unicodeScalars.first?.value else { return total }
            let wide = (0x1100...0x115F).contains(scalar) || (0x2E80...0xA4CF).contains(scalar)
                || (0xAC00...0xD7A3).contains(scalar) || (0xF900...0xFAFF).contains(scalar)
                || (0xFE30...0xFE4F).contains(scalar) || (0xFF00...0xFF60).contains(scalar)
                || (0xFFE0...0xFFE6).contains(scalar) || (0x1F300...0x1FAFF).contains(scalar)
                || scalar >= 0x20000
            return total + (wide ? 2 : 1)
        }
    }
}
