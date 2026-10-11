import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm's UIKit terminal, wired to a `TerminalSession`.
struct TerminalHostView: UIViewRepresentable {
    @ObservedObject var session: TerminalSession
    var fontSize: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
        view.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        view.optionAsMetaKey = true
        view.inputAccessoryView = KeyBar(terminal: view, session: session)
        session.attach(view: view)
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if view.font.pointSize != fontSize {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession

        init(session: TerminalSession) {
            self.session = session
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { session.send(Array(data)) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            MainActor.assumeIsolated { session.setTitle(title) }
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
            UIApplication.shared.open(url)
        }

        func bell(source: TerminalView) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Keyboard accessory row: terminal keys a phone keyboard lacks, plus herdr shortcuts.
final class KeyBar: UIInputView {
    private weak var terminal: TerminalView?
    private weak var session: TerminalSession?
    private var ctrlButton: UIButton?

    private struct Key {
        var title: String
        var symbol: String?
        var action: (KeyBar) -> Void
    }

    init(terminal: TerminalView, session: TerminalSession) {
        self.terminal = terminal
        self.session = session
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
        NotificationCenter.default.addObserver(
            self, selector: #selector(ctrlReset), name: .terminalViewControlModifierReset, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

    private var keys: [Key] {
        [
            Key(title: "esc") { $0.send([0x1b]) },
            Key(title: "ctrl") { $0.toggleCtrl() },
            Key(title: "tab") { $0.send([0x09]) },
            Key(title: "", symbol: "arrow.up") { $0.arrow(app: EscapeSequences.moveUpApp, normal: EscapeSequences.moveUpNormal) },
            Key(title: "", symbol: "arrow.down") { $0.arrow(app: EscapeSequences.moveDownApp, normal: EscapeSequences.moveDownNormal) },
            Key(title: "", symbol: "arrow.left") { $0.arrow(app: EscapeSequences.moveLeftApp, normal: EscapeSequences.moveLeftNormal) },
            Key(title: "", symbol: "arrow.right") { $0.arrow(app: EscapeSequences.moveRightApp, normal: EscapeSequences.moveRightNormal) },
            // herdr's prefix key (tmux-style). Follow with a herdr binding, e.g. `q` to detach.
            Key(title: "^B") { $0.send([0x02]) },
            Key(title: "^C") { $0.send([0x03]) },
            Key(title: "/") { $0.send(Array("/".utf8)) },
            Key(title: "|") { $0.send(Array("|".utf8)) },
            Key(title: "-") { $0.send(Array("-".utf8)) },
            Key(title: "~") { $0.send(Array("~".utf8)) },
            Key(title: "", symbol: "doc.on.clipboard") { $0.paste() },
            Key(title: "", symbol: "keyboard.chevron.compact.down") { $0.terminal?.resignFirstResponder() },
        ]
    }

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
                guard let self else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                key.action(self)
            })
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            if key.title == "ctrl" { ctrlButton = button }
            stack.addArrangedSubview(button)
        }
    }

    private func send(_ bytes: [UInt8]) {
        terminal?.send(data: bytes[...])
    }

    private func arrow(app: [UInt8], normal: [UInt8]) {
        let applicationCursor = terminal?.getTerminal().applicationCursor ?? false
        send(applicationCursor ? app : normal)
    }

    private func toggleCtrl() {
        guard let terminal else { return }
        terminal.controlModifier.toggle()
        updateCtrl()
    }

    @objc private func ctrlReset() {
        updateCtrl()
    }

    private func updateCtrl() {
        let on = terminal?.controlModifier ?? false
        ctrlButton?.configuration?.baseBackgroundColor = on ? .tintColor : nil
        ctrlButton?.configuration?.baseForegroundColor = on ? .white : nil
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        let bracketed = terminal?.getTerminal().bracketedPasteMode ?? false
        if bracketed {
            send([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e] + Array(text.utf8) + [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
        } else {
            send(Array(text.utf8))
        }
    }
}
