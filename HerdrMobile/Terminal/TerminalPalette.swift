import HerdrKit
import SwiftUI

/// Maps terminal colors to SwiftUI, matching the terminal view's dark theme.
enum TerminalPalette {
    static let foreground = Color(white: 0.9)
    static let background = Color(red: 0.06, green: 0.07, blue: 0.09)

    /// xterm's default 16 colors.
    private static let base: [(Double, Double, Double)] = [
        (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
        (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
        (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
        (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255),
    ]

    static func color(_ color: TerminalColor) -> Color {
        switch color {
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .indexed(let index):
            let i = Int(index)
            if i < 16 {
                let (r, g, b) = base[i]
                return Color(red: r / 255, green: g / 255, blue: b / 255)
            }
            if i < 232 {
                // 6×6×6 color cube.
                let levels: [Double] = [0, 95, 135, 175, 215, 255]
                let n = i - 16
                return Color(red: levels[n / 36] / 255, green: levels[(n / 6) % 6] / 255, blue: levels[n % 6] / 255)
            }
            let gray = Double(8 + (i - 232) * 10) / 255
            return Color(white: gray)
        }
    }

    static func attributed(_ lines: [[ANSISpan]]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            for span in line {
                var piece = AttributedString(span.text)
                let style = span.style
                var fg = style.foreground.map(color) ?? foreground
                var bg = style.background.map(color)
                if style.inverse {
                    (fg, bg) = (bg ?? background, fg)
                }
                piece.foregroundColor = style.dim ? fg.opacity(0.6) : fg
                if let bg { piece.backgroundColor = bg }
                if style.bold { piece.inlinePresentationIntent = .stronglyEmphasized }
                if style.italic { piece.inlinePresentationIntent = (piece.inlinePresentationIntent ?? []).union(.emphasized) }
                if style.underline { piece.underlineStyle = .single }
                result += piece
            }
        }
        return result.characters.isEmpty ? AttributedString(" ") : result
    }
}
