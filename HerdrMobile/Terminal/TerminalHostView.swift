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
        view.inputAccessoryView = KeyBar(terminal: view)
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

