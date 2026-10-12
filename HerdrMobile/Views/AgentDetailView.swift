import HerdrKit
import SwiftUI
import UIKit

/// Read an agent's recent output and answer it without opening the terminal.
struct AgentDetailView: View {
    @ObservedObject var session: TerminalSession
    let agentID: String
    var openInTerminal: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var output = AttributedString(" ")
    /// Widest line, in terminal columns.
    @State private var columns = 0
    /// Pinch multiplier on top of the fit-to-width font size.
    @AppStorage("agentOutputZoom") private var zoom: Double = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var prompt = ""
    /// Top of the keyboard in window coordinates, while it's up.
    @State private var keyboardTop: CGFloat?
    /// Bottom of the sheet's content after SwiftUI's own keyboard avoidance.
    @State private var contentBottom: CGFloat = 0
    @State private var mode: Mode = .chat
    @State private var transcript = ClaudeTranscript()
    /// Transcript file and bytes already read, for incremental fetches.
    @State private var transcriptPath: String?
    @State private var transcriptSize = 0
    /// False when the transcript can't be found or parsed: show the terminal instead.
    @State private var chatAvailable = true

    enum Mode: Hashable { case chat, terminal }
    @State private var busy = false
    @State private var error: String?
    @FocusState private var promptFocused: Bool

    init(session: TerminalSession, agentID: String, openInTerminal: @escaping () -> Void) {
        self.session = session
        self.agentID = agentID
        self.openInTerminal = openInTerminal
    }

    /// Live copy from the latest snapshot so the status updates while the sheet is open.
    private var agent: AgentInfo? {
        session.snapshot?.agents.first { $0.id == agentID }
    }

    var body: some View {
        page
    }

    private var page: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isAmbiguous && !chatAvailable {
                    Text("Another Claude runs in this folder, so Shello can't tell their chats apart. Run `herdr integration install claude` on the server to get chat view for both.")
                        .font(.caption)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.yellow.opacity(0.35))
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink).frame(height: Theme.line) }
                } else if canChat && chatAvailable {
                    BlockSegmented(selection: $mode, options: [(.chat, "Chat"), (.terminal, "Terminal")])
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Theme.paper)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink).frame(height: Theme.line) }
                }
                if showsChat {
                    AgentChatView(items: transcript.items, status: agent?.agentStatus ?? .unknown)
                } else {
                    terminalOutput
                }

                if let error {
                    Text(error)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Theme.coral)
                }

                controls
                    .padding(16)
                    .background(Theme.paper)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.ink).frame(height: Theme.line) }
                // SwiftUI usually lifts the controls above the keyboard by itself, but on some
                // devices it stops a little short. Cover only whatever overlap remains; the
                // measured frame below doesn't move with this padding, so it can't stack up.
                Theme.paper.frame(height: keyboardOverlap)
            }
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { contentBottom = proxy.frame(in: .global).maxY }
                    .onChange(of: proxy.frame(in: .global).maxY) { _, bottom in contentBottom = bottom }
            })
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                keyboardTop = frame.minY >= UIScreen.main.bounds.height ? nil : frame.minY
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardTop = nil
            }
            .navigationTitle(agent.map(title) ?? "Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(Theme.ink)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(busy)
                }
            }
            .task { await reload() }
            #if DEBUG
            .task {
                if ProcessInfo.processInfo.arguments.contains("-focusPrompt") {
                    try? await Task.sleep(for: .seconds(1))
                    promptFocused = true
                }
            }
            #endif
            .task(id: agent?.agentStatus) {
                // A question or approval reads best as the agent draws it: show the terminal.
                if agent?.agentStatus == .blocked { mode = .terminal }
                // Re-read when the state changes (e.g. the agent finishes a turn).
                if columns > 0 || !transcript.items.isEmpty { await reload() }
            }
            .task(id: mode) {
                if mode == .terminal, columns == 0 { await reloadTerminal() }
                // Follow the conversation live; reads are incremental, so this stays cheap.
                while !Task.isCancelled, showsChat {
                    let active = agent?.agentStatus == .working || agent?.agentStatus == .blocked
                    try? await Task.sleep(for: active ? .seconds(2) : .seconds(6))
                    guard !Task.isCancelled else { return }
                    await reloadChat(quiet: true)
                }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if let agent {
                HStack {
                    StatusBadge(status: agent.agentStatus)
                    Text(agent.agentStatus.rawValue.uppercased()).font(Theme.mono(13, .heavy)).foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Open in terminal") {
                        Task {
                            await run { try await $0.focus(agent) }
                            openInTerminal()
                        }
                    }
                    .buttonStyle(BlockButtonStyle(fill: Theme.card, foreground: Theme.ink, compact: true))
                }

                if agent.agentStatus == .blocked {
                    // Agents' approval dialogs are menus: Enter accepts the highlighted
                    // choice, digits pick an option, Esc cancels.
                    HStack(spacing: 8) {
                        keyButton("Approve", keys: ["enter"], tint: Theme.mint)
                        keyButton("1", keys: ["1"])
                        keyButton("2", keys: ["2"])
                        keyButton("3", keys: ["3"])
                        keyButton("Reject", keys: ["esc"], tint: Theme.coral)
                    }
                    HStack(spacing: 8) {
                        keyButton("↑", keys: ["up"])
                        keyButton("↓", keys: ["down"])
                        keyButton("Tab", keys: ["tab"])
                        keyButton("^C", keys: ["ctrl+c"])
                    }
                } else if agent.agentStatus == .working {
                    HStack {
                        keyButton("Interrupt (esc)", keys: ["esc"], tint: Theme.yellow)
                        keyButton("^C", keys: ["ctrl+c"])
                    }
                }

                HStack(alignment: .bottom) {
                    TextField(agent.agentStatus == .blocked ? "Answer, then press Approve…" : "Prompt \(title(agent))…", text: $prompt, axis: .vertical)
                        .lineLimit(1...6)
                        .field()
                        .focused($promptFocused)
                    if promptFocused {
                        Button {
                            promptFocused = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 15, weight: .bold))
                        }
                        .buttonStyle(BlockButtonStyle(fill: Theme.card, foreground: Theme.ink, compact: true))
                        .accessibilityLabel("Hide keyboard")
                    }
                    Button {
                        send(agent)
                    } label: {
                        Image(systemName: "arrow.up").font(.system(size: 16, weight: .heavy))
                    }
                    .buttonStyle(BlockButtonStyle(compact: true))
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            } else {
                Text("This agent is no longer running.").foregroundStyle(Theme.muted)
            }
        }
    }

    private var keyboardOverlap: CGFloat {
        guard let keyboardTop else { return 0 }
        return max(0, contentBottom - keyboardTop)
    }

    private var showsChat: Bool {
        mode == .chat && chatAvailable && canChat
    }

    private var canChat: Bool { agent?.hasTranscript == true }

    /// Another agent shares the folder, so "newest transcript there" can't be trusted;
    /// only exact lookups (integration or the pane's process) are used.
    private var isAmbiguous: Bool {
        guard let agent, agent.hasTranscript else { return false }
        return session.snapshot?.transcriptIsAmbiguous(for: agent) == true
    }

    private var terminalOutput: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                // Lines keep the pane's own wrapping so rules and boxes line up;
                // scroll sideways if they don't fit even at the smallest size.
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(output)
                            .font(.system(size: fontSize(fitting: geometry.size.width), design: .monospaced))
                            .fixedSize()
                            .textSelection(.enabled)
                            .padding(10)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                }
                .background(TerminalPalette.background)
                .foregroundStyle(TerminalPalette.foreground)
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in zoom = min(max(zoom * value.magnification, 0.25), 4) }
                )
                .onChange(of: output) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func title(_ agent: AgentInfo) -> String {
        session.snapshot?.displayName(for: agent) ?? agent.displayName
    }

    /// Monospaced size at which the widest line fills the view, then scaled by the pinch zoom.
    /// The automatic size never drops below 9 pt so it stays legible on small phones;
    /// wider output scrolls sideways instead. Pinching can still go smaller.
    private func fontSize(fitting width: CGFloat) -> CGFloat {
        // SF Mono advances about 0.6em per column.
        let fit = min(max((width - 20) / (CGFloat(max(columns, 20)) * 0.6), 9), 13)
        return min(max(fit * zoom * pinch, 3), 40)
    }

    private func keyButton(_ title: String, keys: [String], tint: Color? = nil) -> some View {
        Button(title) {
            guard let agent else { return }
            Task {
                await run { try await $0.sendKeys(agent, keys: keys) }
                try? await Task.sleep(for: .milliseconds(400))
                await reload()
            }
        }
        .buttonStyle(BlockButtonStyle(fill: tint ?? Theme.card, foreground: tint == nil ? Theme.ink : Theme.onAccent, compact: true))
        .disabled(busy)
    }

    private func send(_ agent: AgentInfo) {
        let text = prompt
        Task {
            if agent.agentStatus == .blocked {
                // `agent prompt` refuses blocked agents; type the text into the dialog instead.
                await run { try await $0.type(agent, text: text) }
            } else {
                await run { try await $0.prompt(agent, text: text) }
            }
            if error == nil { prompt = "" }
            await session.refreshAgents()
            try? await Task.sleep(for: .milliseconds(600))
            await reload()
        }
    }

    private func reload() async {
        if showsChat {
            await reloadChat(quiet: false)
        }
        if !showsChat {
            await reloadTerminal()
        }
    }

    /// Pulls new transcript lines; falls back to the terminal view if there's no usable transcript.
    private func reloadChat(quiet: Bool) async {
        #if DEBUG
        if ReadmeDemo.isOn {
            transcript = ReadmeDemo.transcript
            return
        }
        #endif
        guard let agent, let remote = session.herdr else { return }
        let known = transcriptPath.map { ($0, transcriptSize) }
        do {
            guard let chunk = try await remote.readTranscript(agent, allowFolderGuess: !isAmbiguous, known: known) else {
                if transcript.items.isEmpty { chatAvailable = false }
                return
            }
            if !chunk.isIncremental || chunk.path != transcriptPath {
                // New file (e.g. after /clear) or first read: start over.
                transcript = ClaudeTranscript()
            }
            transcript.ingest(chunk.body)
            transcriptPath = chunk.path
            transcriptSize = chunk.consumed
            if transcript.items.isEmpty { chatAvailable = false }
        } catch {
            if !quiet { self.error = error.localizedDescription }
        }
        if !chatAvailable { await reloadTerminal() }
    }

    private func reloadTerminal() async {
        guard let agent else { return }
        await run { remote in
            // `recent` keeps the pane's line breaks; `ansi` keeps its colors.
            let text = try await remote.readAgent(agent, lines: 300, source: .recent, ansi: true)
            let lines = ANSIParser.lines(text)
            let styled = TerminalPalette.attributed(lines)
            let widest = lines.map { ANSIParser.displayColumns($0.map(\.text).joined()) }.max() ?? 0
            await MainActor.run {
                output = styled
                columns = widest
            }
        }
    }

    private func run(_ body: @escaping (HerdrRemote) async throws -> Void) async {
        guard let remote = session.herdr else {
            error = "Not connected."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await body(remote)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
