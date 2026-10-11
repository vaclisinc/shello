import SwiftUI
import UIKit

/// Shello's look: paper background, ink borders, square corners and hard offset
/// shadows, with the icon's yellow as the accent. Light by default.
enum Theme {
    static let paper = dynamic(light: 0xF4EFEA, dark: 0x161616)
    static let card = dynamic(light: 0xFFFDF8, dark: 0x222222)
    static let ink = dynamic(light: 0x262626, dark: 0xF4EFEA)
    static let muted = dynamic(light: 0x6E6A64, dark: 0xA9A49D)
    static let field = dynamic(light: 0xFFFFFF, dark: 0x1B1B1B)

    static let yellow = Color(hex: 0xFDBE3B)
    static let sky = Color(hex: 0x6FC2FF)
    static let coral = Color(hex: 0xFF7169)
    static let mint = Color(hex: 0x38C98B)
    /// Text on yellow/sky/coral fills, which stay light in both modes.
    static let onAccent = Color(hex: 0x1E1E1E)

    static let line: CGFloat = 2
    static let shadow: CGFloat = 4

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    static let storageKey = "appearance"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "Match System"
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

// MARK: Components

/// A square card with an ink border and a hard shadow.
struct CardModifier: ViewModifier {
    var fill: Color = Theme.card
    var shadow: CGFloat = Theme.shadow

    func body(content: Content) -> some View {
        content
            .background(fill)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.line))
            .background(Rectangle().fill(Theme.ink).offset(x: shadow, y: shadow))
            .padding(.trailing, shadow)
            .padding(.bottom, shadow)
    }
}

extension View {
    func card(fill: Color = Theme.card, shadow: CGFloat = Theme.shadow) -> some View {
        modifier(CardModifier(fill: fill, shadow: shadow))
    }

    /// Paper background and ink-colored chrome for a whole screen.
    func paperScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.paper.ignoresSafeArea())
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(Theme.ink)
    }

    /// Plain list rows that carry their own card styling.
    func cardRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// Chunky square button: uppercase mono label, ink border, shadow that sinks when pressed.
struct BlockButtonStyle: ButtonStyle {
    var fill: Color = Theme.yellow
    var foreground: Color = Theme.onAccent
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let depth: CGFloat = compact ? 2 : 3
        configuration.label
            .font(Theme.mono(compact ? 12 : 14))
            .textCase(.uppercase)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 7 : 11)
            .frame(minWidth: compact ? 36 : nil)
            .background(fill)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.line))
            .offset(x: pressed ? depth : 0, y: pressed ? depth : 0)
            .background(Rectangle().fill(Theme.ink).offset(x: depth, y: depth))
            .padding(.trailing, depth)
            .padding(.bottom, depth)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

/// Small uppercase mono heading used above groups.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.mono(11))
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(Theme.muted)
    }
}

/// Square, bordered input field.
struct FieldModifier: ViewModifier {
    var monospaced = false

    func body(content: Content) -> some View {
        content
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.field)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
    }
}

extension View {
    func field(monospaced: Bool = false) -> some View {
        modifier(FieldModifier(monospaced: monospaced))
    }
}

/// Two-or-more option switch with square segments; the selection is filled yellow.
struct BlockSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(Theme.mono(12))
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(selected ? Theme.onAccent : Theme.ink)
                        .background(selected ? Theme.yellow : Theme.field)
                }
                .buttonStyle(.plain)
                if index < options.count - 1 {
                    Rectangle().fill(Theme.ink).frame(width: 1.5)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.line))
    }
}
