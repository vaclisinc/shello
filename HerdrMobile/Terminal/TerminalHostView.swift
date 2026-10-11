import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm's UIKit terminal, wired to a `TerminalSession`.
struct TerminalHostView: UIViewRepresentable {
    @ObservedObject var session: TerminalSession
    var fontSize: CGFloat
    /// Called with the final size when a pinch-to-zoom gesture ends.
    var onFontSizeChange: (CGFloat) -> Void = { _ in }

    static let fontSizeRange: ClosedRange<CGFloat> = 4...32

    /// Starting size: about 72 columns across the phone's portrait width, so herdr's
    /// panes and agent UIs have room on every iPhone (≈10 pt on Pro Max, ≈9 pt on smaller ones).
    @MainActor static var defaultFontSize: Double {
        let bounds = UIScreen.main.bounds
        let portraitWidth = min(bounds.width, bounds.height)
        return Double(min(max((portraitWidth / (72 * 0.6)).rounded(), 8), 11))
    }

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
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        view.addGestureRecognizer(pinch)
        context.coordinator.onFontSizeChange = onFontSizeChange
        session.attach(view: view)
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.onFontSizeChange = onFontSizeChange
        // While pinching, the gesture owns the font size; don't snap back to the stored value.
        if !context.coordinator.isPinching, view.font.pointSize != fontSize {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession
        var onFontSizeChange: (CGFloat) -> Void = { _ in }
        private(set) var isPinching = false
        private var pinchStartSize: CGFloat = 0

        init(session: TerminalSession) {
            self.session = session
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view as? TerminalView else { return }
            switch gesture.state {
            case .began:
                isPinching = true
                pinchStartSize = view.font.pointSize
            case .changed:
                // Step in half points so the terminal (and remote PTY) only resizes when the size actually changes.
                let range = TerminalHostView.fontSizeRange
                let size = min(max((pinchStartSize * gesture.scale * 2).rounded() / 2, range.lowerBound), range.upperBound)
                if size != view.font.pointSize {
                    view.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
                }
            default:
                isPinching = false
                onFontSizeChange(view.font.pointSize)
            }
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

