import HerdrKit
import SwiftTerm
import UIKit

/// Keyboard accessory row: keys and modifier combos a phone keyboard can't
/// produce (Shift+Tab, Shift+Enter, Ctrl/Alt chords, arrows), plus herdr shortcuts.
///
/// Modifiers are sticky: tap once to apply to the next key, double-tap to lock.
/// Ctrl and Alt also apply to letters typed on the software keyboard.
final class KeyBar: UIInputView {
    private enum ModifierState { case off, once, locked }

    private weak var terminal: TerminalView?
    private var shift: ModifierState = .off
    private var ctrl: ModifierState = .off
    private var alt: ModifierState = .off
    private var lastTap: (title: String, time: Date)?
    private var modifierButtons: [String: UIButton] = [:]

    private enum Action {
        case key(TerminalKey)
        /// A key that always carries extra modifiers, e.g. ⇧Tab.
        case combo(TerminalKey, KeyModifiers)
        case raw([UInt8])
        case shift, ctrl, alt
        case paste, dismiss
    }

    private struct Key {
        var title: String
        var symbol: String? = nil
        var action: Action
    }

    private let keys: [Key] = [
        Key(title: "esc", action: .key(.escape)),
        Key(title: "⇧", action: .shift),
        Key(title: "ctrl", action: .ctrl),
        Key(title: "alt", action: .alt),
        Key(title: "tab", action: .key(.tab)),
        Key(title: "⇧tab", action: .combo(.tab, .shift)),
        Key(title: "⏎", action: .key(.enter)),
        Key(title: "⇧⏎", action: .combo(.enter, .shift)),
        Key(title: "", symbol: "arrow.up", action: .key(.up)),
        Key(title: "", symbol: "arrow.down", action: .key(.down)),
        Key(title: "", symbol: "arrow.left", action: .key(.left)),
        Key(title: "", symbol: "arrow.right", action: .key(.right)),
        // herdr's tmux-style prefix; follow with a herdr binding (e.g. `q` detaches).
        Key(title: "^B", action: .raw([0x02])),
        Key(title: "^C", action: .raw([0x03])),
        Key(title: "|", action: .key(.char("|"))),
        Key(title: "/", action: .key(.char("/"))),
        Key(title: "-", action: .key(.char("-"))),
        Key(title: "~", action: .key(.char("~"))),
        Key(title: "`", action: .key(.char("`"))),
        Key(title: "home", action: .key(.home)),
        Key(title: "end", action: .key(.end)),
        Key(title: "pgup", action: .key(.pageUp)),
        Key(title: "pgdn", action: .key(.pageDown)),
        Key(title: "", symbol: "doc.on.clipboard", action: .paste),
        Key(title: "", symbol: "keyboard.chevron.compact.down", action: .dismiss),
    ]

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
        // SwiftTerm clears its ctrl/meta flags after each typed character.
        NotificationCenter.default.addObserver(
            self, selector: #selector(terminalClearedModifier), name: .terminalViewControlModifierReset, object: terminal
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(terminalClearedModifier), name: .terminalViewMetaModifierReset, object: terminal
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

    // MARK: Layout

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -5),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -10),
        ])

        for key in keys {
            var config = UIButton.Configuration.gray()
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            if let symbol = key.symbol {
                config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            } else {
                var title = AttributedString(key.title)
                title.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
                config.attributedTitle = title
            }
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                self?.perform(key)
            })
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            button.accessibilityLabel = key.symbol ?? key.title
            switch key.action {
            case .shift, .ctrl, .alt: modifierButtons[key.title] = button
            default: break
            }
            stack.addArrangedSubview(button)
        }
    }

    // MARK: Actions

    private func perform(_ key: Key) {
        switch key.action {
        case .shift:
            shift = cycle(shift, title: key.title)
            refreshModifiers()
        case .ctrl:
            ctrl = cycle(ctrl, title: key.title)
            refreshModifiers()
        case .alt:
            alt = cycle(alt, title: key.title)
            refreshModifiers()
        case .key(let terminalKey):
            send(terminalKey, extra: [])
        case .combo(let terminalKey, let extra):
            send(terminalKey, extra: extra)
        case .raw(let bytes):
            terminal?.send(data: bytes[...])
            consumeOneShotModifiers()
        case .paste:
            paste()
        case .dismiss:
            terminal?.resignFirstResponder()
        }
    }

    /// Tap: off → once (next key only). Quick second tap: locked. Tap again: off.
    private func cycle(_ state: ModifierState, title: String) -> ModifierState {
        let now = Date()
        let isDoubleTap = lastTap.map { $0.title == title && now.timeIntervalSince($0.time) < 0.35 } ?? false
        lastTap = (title, now)
        switch state {
        case .off: return .once
        case .once: return isDoubleTap ? .locked : .off
        case .locked: return .off
        }
    }

    private var activeModifiers: KeyModifiers {
        var modifiers: KeyModifiers = []
        if shift != .off { modifiers.insert(.shift) }
        if ctrl != .off { modifiers.insert(.ctrl) }
        if alt != .off { modifiers.insert(.alt) }
        return modifiers
    }

    private func send(_ key: TerminalKey, extra: KeyModifiers) {
        guard let terminal else { return }
        let state = terminal.getTerminal()
        let bytes = KeyEncoder.encode(
            key,
            modifiers: activeModifiers.union(extra),
            kitty: !state.keyboardEnhancementFlags.isEmpty,
            applicationCursor: state.applicationCursor
        )
        terminal.send(data: bytes[...])
        consumeOneShotModifiers()
    }

    private func consumeOneShotModifiers() {
        if shift == .once { shift = .off }
        if ctrl == .once { ctrl = .off }
        if alt == .once { alt = .off }
        refreshModifiers()
    }

    /// The software keyboard path in SwiftTerm consumed ctrl/meta for a typed letter.
    @objc private func terminalClearedModifier() {
        // Defer: this fires from inside SwiftTerm's property observer.
        DispatchQueue.main.async { [weak self] in self?.syncAfterTypedCharacter() }
    }

    private func syncAfterTypedCharacter() {
        if ctrl == .once, terminal?.controlModifier == false { ctrl = .off }
        if alt == .once, terminal?.metaModifier == false { alt = .off }
        if shift == .once { shift = .off }
        refreshModifiers()
    }

    private func refreshModifiers() {
        // Mirror ctrl/alt into SwiftTerm so letters typed on the software keyboard get them too.
        if let terminal {
            if terminal.controlModifier != (ctrl != .off) { terminal.controlModifier = ctrl != .off }
            if terminal.metaModifier != (alt != .off) { terminal.metaModifier = alt != .off }
        }
        style(modifierButtons["⇧"], shift)
        style(modifierButtons["ctrl"], ctrl)
        style(modifierButtons["alt"], alt)
    }

    private func style(_ button: UIButton?, _ state: ModifierState) {
        guard let button, var config = button.configuration else { return }
        switch state {
        case .off:
            config.baseBackgroundColor = nil
            config.baseForegroundColor = nil
            config.background.strokeWidth = 0
        case .once:
            config.baseBackgroundColor = .tintColor
            config.baseForegroundColor = .white
            config.background.strokeWidth = 0
        case .locked:
            config.baseBackgroundColor = .tintColor
            config.baseForegroundColor = .white
            config.background.strokeColor = .white
            config.background.strokeWidth = 2
        }
        button.configuration = config
    }

    private func paste() {
        guard let terminal, let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if terminal.getTerminal().bracketedPasteMode {
            terminal.send(data: ([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e] + Array(text.utf8) + [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])[...])
        } else {
            terminal.send(data: Array(text.utf8)[...])
        }
    }
}
