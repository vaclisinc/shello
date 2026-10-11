import Foundation

/// Modifier bits as used by xterm (`CSI 1;<1+bits>A`) and the kitty keyboard protocol.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1)
    public static let alt = KeyModifiers(rawValue: 2)
    public static let ctrl = KeyModifiers(rawValue: 4)

    /// The `<mods>` parameter: 1 + modifier bits.
    var parameter: Int { 1 + rawValue }
}

public enum TerminalKey: Hashable, Sendable {
    case enter, tab, escape, backspace
    case up, down, left, right
    case home, end, pageUp, pageDown
    case char(Character)
}

/// Turns a key plus modifiers into the bytes a terminal would send.
///
/// herdr enables the kitty keyboard protocol on its host terminal, which is
/// the only way combos like Shift+Enter or Ctrl+Tab survive the trip to the
/// agent running inside a pane. When the app on the other end hasn't asked for
/// it, we fall back to the usual xterm encodings.
public enum KeyEncoder {
    public static func encode(
        _ key: TerminalKey,
        modifiers: KeyModifiers = [],
        kitty: Bool,
        applicationCursor: Bool = false
    ) -> [UInt8] {
        kitty
            ? encodeKitty(key, modifiers, applicationCursor)
            : encodeLegacy(key, modifiers, applicationCursor)
    }

    private static let esc: UInt8 = 0x1b

    private static func csi(_ body: String) -> [UInt8] {
        [esc, UInt8(ascii: "[")] + Array(body.utf8)
    }

    private static func cursor(_ final: Character, _ modifiers: KeyModifiers, _ applicationCursor: Bool) -> [UInt8] {
        if !modifiers.isEmpty { return csi("1;\(modifiers.parameter)\(final)") }
        if applicationCursor { return [esc, UInt8(ascii: "O")] + Array(String(final).utf8) }
        return csi(String(final))
    }

    private static func tilde(_ number: Int, _ modifiers: KeyModifiers) -> [UInt8] {
        modifiers.isEmpty ? csi("\(number)~") : csi("\(number);\(modifiers.parameter)~")
    }

    private static func cursorFinal(_ key: TerminalKey) -> Character? {
        switch key {
        case .up: return "A"
        case .down: return "B"
        case .right: return "C"
        case .left: return "D"
        case .home: return "H"
        case .end: return "F"
        default: return nil
        }
    }

    // MARK: kitty (CSI u)

    private static func encodeKitty(_ key: TerminalKey, _ modifiers: KeyModifiers, _ applicationCursor: Bool) -> [UInt8] {
        func csiU(_ code: UInt32) -> [UInt8] {
            modifiers.isEmpty ? csi("\(code)u") : csi("\(code);\(modifiers.parameter)u")
        }
        if let final = cursorFinal(key) { return cursor(final, modifiers, applicationCursor) }
        switch key {
        case .enter: return modifiers.isEmpty ? [0x0d] : csiU(13)
        case .tab: return modifiers.isEmpty ? [0x09] : csiU(9)
        case .backspace: return modifiers.isEmpty ? [0x7f] : csiU(127)
        case .escape: return csiU(27)
        case .pageUp: return tilde(5, modifiers)
        case .pageDown: return tilde(6, modifiers)
        case .char(let character):
            if modifiers.subtracting(.shift).isEmpty {
                let text = modifiers.contains(.shift) ? String(character).uppercased() : String(character)
                return Array(text.utf8)
            }
            // Keys are reported by their unshifted code point.
            let base = String(character).lowercased().unicodeScalars.first?.value ?? 0
            return csiU(base)
        default:
            return []
        }
    }

    // MARK: legacy (xterm)

    private static func encodeLegacy(_ key: TerminalKey, _ modifiers: KeyModifiers, _ applicationCursor: Bool) -> [UInt8] {
        let altPrefix: [UInt8] = modifiers.contains(.alt) ? [esc] : []
        if let final = cursorFinal(key) { return cursor(final, modifiers, applicationCursor) }
        switch key {
        case .enter:
            // No standard Shift+Enter in legacy terminals; ESC CR is what
            // Claude Code, Codex and most TUIs read as "insert newline".
            if modifiers.contains(.shift) || modifiers.contains(.alt) { return [esc, 0x0d] }
            return [0x0d]
        case .tab:
            if modifiers.contains(.shift) { return csi("Z") }
            return altPrefix + [0x09]
        case .backspace:
            return altPrefix + [modifiers.contains(.ctrl) ? 0x08 : 0x7f]
        case .escape:
            return altPrefix + [esc]
        case .pageUp: return tilde(5, modifiers)
        case .pageDown: return tilde(6, modifiers)
        case .char(let character):
            var text = String(character)
            if modifiers.contains(.shift) { text = text.uppercased() }
            if modifiers.contains(.ctrl), let control = controlByte(for: character) {
                return altPrefix + [control]
            }
            return altPrefix + Array(text.utf8)
        default:
            return []
        }
    }

    /// Ctrl+key in a classic terminal: `a`–`z` → 1–26, plus `@ [ \ ] ^ _ space ?`.
    static func controlByte(for character: Character) -> UInt8? {
        guard let ascii = String(character).lowercased().unicodeScalars.first?.value, ascii < 128 else { return nil }
        switch ascii {
        case 0x61...0x7a: return UInt8(ascii - 0x60)
        case 0x40, 0x20, 0x32: return 0x00
        case 0x5b, 0x33: return 0x1b
        case 0x5c, 0x34: return 0x1c
        case 0x5d, 0x35: return 0x1d
        case 0x5e, 0x36: return 0x1e
        case 0x5f, 0x2d, 0x37: return 0x1f
        case 0x3f, 0x38: return 0x7f
        default: return nil
        }
    }
}
