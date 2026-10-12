import HerdrKit
import SwiftUI
import UIKit

/// An agent's conversation as chat, laid out like Claude's own apps: your prompts in
/// bubbles, replies as plain Markdown, and runs of tool calls folded into one line.
struct AgentChatView: View {
    let items: [TranscriptItem]
    let status: AgentStatus
    @State private var viewing: ViewedImage?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                    if status == .working {
                        WorkingIndicator()
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .background(Theme.paper)
            .defaultScrollAnchor(.bottom)
            .onChange(of: items.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .fullScreenCover(item: $viewing) { image in
            ImageViewer(image: image.image)
        }
    }

    // MARK: Rows

    private enum Row: Identifiable {
        case user(id: String, text: String, images: [Data])
        case assistant(id: String, text: String)
        case tools([TranscriptTool])
        case compacted(id: String, summary: String)

        var id: String {
            switch self {
            case .user(let id, _, _), .assistant(let id, _), .compacted(let id, _): return id
            case .tools(let tools): return "tools-" + (tools.first?.id ?? "")
            }
        }
    }

    /// Consecutive tool calls collapse into one row.
    private var rows: [Row] {
        var rows: [Row] = []
        for item in items {
            switch item {
            case .user(let id, let text, let images):
                rows.append(.user(id: id, text: text, images: images))
            case .assistant(let id, let text):
                rows.append(.assistant(id: id, text: text))
            case .compacted(let id, let summary):
                rows.append(.compacted(id: id, summary: summary))
            case .tool(let tool):
                if case .tools(let tools)? = rows.last {
                    rows[rows.count - 1] = .tools(tools + [tool])
                } else {
                    rows.append(.tools([tool]))
                }
            }
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .user(_, let text, let images):
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 8) {
                    if !images.isEmpty {
                        ImageStrip(images: images) { viewing = ViewedImage(image: $0) }
                    }
                    if !text.isEmpty {
                        Text(text)
                            .font(.body)
                            .foregroundStyle(Theme.onAccent)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .card(fill: Theme.yellow, shadow: 3)
                    }
                }
            }
        case .assistant(_, let text):
            MarkdownView(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .compacted(_, let summary):
            CompactedDivider(summary: summary)
        case .tools(let tools):
            ToolGroup(tools: tools, awaitingApproval: status == .blocked && tools.last?.isPending == true && isLastToolGroup(tools))
        }
    }

    private func isLastToolGroup(_ tools: [TranscriptTool]) -> Bool {
        guard let id = tools.last?.id else { return false }
        return items.last { if case .tool = $0 { return true } else { return false } }?.id == id
    }
}

private struct ViewedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// "Conversation compacted": Claude Code's summary of everything before, folded away.
private struct CompactedDivider: View {
    let summary: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Rectangle().fill(Theme.ink.opacity(0.25)).frame(height: 1.5)
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.compress.vertical")
                        Text("CONVERSATION COMPACTED")
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .font(Theme.mono(10, .heavy))
                    .foregroundStyle(Theme.muted)
                    .fixedSize()
                    Rectangle().fill(Theme.ink.opacity(0.25)).frame(height: 1.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                MarkdownView(text: summary)
                    .padding(12)
                    .background(Theme.card)
                    .overlay(Rectangle().strokeBorder(Theme.ink.opacity(0.4), lineWidth: 1.5))
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Tools

/// "Ran 3 commands ›": tap to list the calls, tap a call to see its output.
private struct ToolGroup: View {
    let tools: [TranscriptTool]
    let awaitingApproval: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if tools.contains(where: { $0.isError }) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.coral)
                    }
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 { Rectangle().fill(Theme.ink.opacity(0.15)).frame(height: 1) }
                        ToolRow(tool: tool, awaitingApproval: awaitingApproval && index == tools.count - 1)
                    }
                }
                .background(Theme.card)
                .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
            }
        }
    }

    /// A pending approval is always shown open so the request is visible.
    private var isOpen: Bool { expanded || awaitingApproval }

    private var summary: String {
        let names = Set(tools.map(\.name))
        let n = tools.count
        if names == ["Bash"] { return n == 1 ? "Ran a command" : "Ran \(n) commands" }
        if names.isSubset(of: ["Read"]) { return n == 1 ? "Read a file" : "Read \(n) files" }
        if names.isSubset(of: ["Edit", "Write", "MultiEdit", "NotebookEdit"]) { return n == 1 ? "Edited a file" : "Edited \(n) files" }
        if names.isSubset(of: ["Grep", "Glob"]) { return n == 1 ? "Searched" : "Searched \(n) times" }
        return n == 1 ? "Used \(tools[0].name)" : "Used \(n) tools"
    }
}

private struct ToolRow: View {
    let tool: TranscriptTool
    let awaitingApproval: Bool
    @State private var showOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if tool.result != nil { withAnimation(.easeOut(duration: 0.15)) { showOutput.toggle() } }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                            .font(Theme.mono(11, .heavy))
                            .foregroundStyle(Theme.muted)
                        Text(tool.summary.isEmpty ? "—" : tool.summary)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(showOutput ? nil : 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if tool.result != nil {
                        Image(systemName: showOutput ? "chevron.up" : "chevron.down")
                            .font(.caption2.bold())
                            .foregroundStyle(Theme.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if awaitingApproval {
                Label("Waiting for your approval", systemImage: "hand.raised.fill")
                    .font(Theme.mono(11, .heavy))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.coral)
                    .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
            }

            if showOutput, let result = tool.result {
                Text(result.isEmpty ? "(no output)" : String(result.prefix(6000)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TerminalPalette.foreground)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TerminalPalette.background)
            }
        }
        .padding(10)
        .background(awaitingApproval ? Theme.coral.opacity(0.15) : Color.clear)
    }

    private var dotColor: Color {
        if awaitingApproval { return Theme.coral }
        if tool.isPending { return Theme.sky }
        return tool.isError ? Theme.coral : Theme.mint
    }
}

// MARK: Markdown

/// Renders agent Markdown: headings, lists, quotes, rules, fenced code with a
/// copy button, and inline `code` as tinted chips.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownParser.blocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: HerdrKit.MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .foregroundStyle(Theme.ink)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Self.inline(text))
                .font(.body)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(marker == "•" ? .body.bold() : .body.monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .frame(minWidth: 18, alignment: .trailing)
                Text(Self.inline(text))
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 18)
        case .quote(let text):
            Text(Self.inline(text))
                .font(.body)
                .foregroundStyle(Theme.muted)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.ink).frame(width: 3) }
        case .code(let language, let text):
            CodeBlock(language: language, code: text)
        case .rule:
            Rectangle().fill(Theme.ink.opacity(0.3)).frame(height: 1.5).padding(.vertical, 4)
        }
    }

    /// Inline Markdown with `code` spans drawn as monospaced chips.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(.callout, design: .monospaced)
            result[run.range].backgroundColor = Theme.yellow.opacity(0.32)
        }
        for run in result.runs where run.link != nil {
            result[run.range].underlineStyle = .single
        }
        return result
    }
}

private struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(TerminalPalette.foreground.opacity(0.6))
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(TerminalPalette.foreground.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(TerminalPalette.foreground.opacity(0.12)).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(TerminalPalette.foreground)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(TerminalPalette.background)
        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
    }
}

// MARK: Images

private struct ImageStrip: View {
    let images: [Data]
    var open: (UIImage) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                if let image = UIImage(data: data) {
                    Button { open(image) } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: images.count == 1 ? 180 : 110, height: images.count == 1 ? 180 : 110)
                            .clipped()
                            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.line))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Full-screen image with pinch to zoom; tap Close or swipe down to dismiss.
private struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale * pinch)
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in scale = min(max(scale * value.magnification, 1), 5) }
                )
                .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button("Close") { dismiss() }
                .buttonStyle(BlockButtonStyle(compact: true))
                .padding()
        }
        .gesture(DragGesture().onEnded { if $0.translation.height > 120 { dismiss() } })
    }
}

private struct WorkingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…").font(.subheadline).foregroundStyle(Theme.muted)
        }
    }
}
