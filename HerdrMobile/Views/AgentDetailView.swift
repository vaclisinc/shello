import HerdrKit
import SwiftUI

/// Read an agent's recent output and answer it without opening the terminal.
struct AgentDetailView: View {
    @ObservedObject var session: TerminalSession
    let agentID: String
    var openInTerminal: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var output = ""
    @State private var prompt = ""
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
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(output.isEmpty ? " " : output)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .background(Color(red: 0.06, green: 0.07, blue: 0.09))
                    .foregroundStyle(Color(white: 0.9))
                    .onChange(of: output) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.top, 6)
                }

                controls
                    .padding()
                    .background(.bar)
            }
            .navigationTitle(agent?.displayName ?? "Agent")
            .navigationBarTitleDisplayMode(.inline)
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
            .task(id: agent?.agentStatus) {
                // Re-read when the state changes (e.g. the agent finishes a turn).
                if !output.isEmpty { await reload() }
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if let agent {
                HStack {
                    StatusBadge(status: agent.agentStatus)
                    Text(agent.agentStatus.rawValue.capitalized).font(.subheadline.bold())
                    Spacer()
                    Button("Open in Terminal") {
                        Task {
                            await run { try await $0.focus(agent) }
                            openInTerminal()
                        }
                    }
                    .font(.subheadline)
                }

                if agent.agentStatus == .blocked {
                    // Agents' approval dialogs are menus: Enter accepts the highlighted
                    // choice, digits pick an option, Esc cancels.
                    HStack(spacing: 8) {
                        keyButton("Approve", keys: ["enter"], tint: .green)
                        keyButton("1", keys: ["1"])
                        keyButton("2", keys: ["2"])
                        keyButton("3", keys: ["3"])
                        keyButton("Reject", keys: ["esc"], tint: .red)
                    }
                    HStack(spacing: 8) {
                        keyButton("↑", keys: ["up"])
                        keyButton("↓", keys: ["down"])
                        keyButton("Tab", keys: ["tab"])
                        keyButton("^C", keys: ["ctrl+c"])
                    }
                } else if agent.agentStatus == .working {
                    HStack {
                        keyButton("Interrupt (Esc)", keys: ["esc"], tint: .orange)
                        keyButton("^C", keys: ["ctrl+c"])
                    }
                }

                HStack(alignment: .bottom) {
                    TextField(agent.agentStatus == .blocked ? "Answer, then press Approve…" : "Prompt \(agent.displayName)…", text: $prompt, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.roundedBorder)
                        .focused($promptFocused)
                    Button {
                        send(agent)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            } else {
                Text("This agent is no longer running.").foregroundStyle(.secondary)
            }
        }
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
        .buttonStyle(.bordered)
        .tint(tint)
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
        guard let agent else { return }
        await run { remote in
            let text = try await remote.readAgent(agent, lines: 300)
            await MainActor.run { output = text }
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
