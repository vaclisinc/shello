import HerdrKit
import SwiftUI

struct SessionView: View {
    @ObservedObject var session: TerminalSession
    @AppStorage("terminalFontSize") private var fontSize: Double = 13
    @State private var tab: Tab = .terminal

    enum Tab: Hashable { case terminal, agents }

    init(session: TerminalSession) {
        self.session = session
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                Text("Terminal").tag(Tab.terminal)
                Text(agentsTabTitle).tag(Tab.agents)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)

            ZStack {
                // Keep the terminal alive (and its scrollback) while the agents tab is shown.
                TerminalHostView(session: session, fontSize: fontSize)
                    .opacity(tab == .terminal ? 1 : 0)
                    .allowsHitTesting(tab == .terminal)
                if tab == .agents {
                    AgentsView(session: session) { tab = .terminal }
                        .background(Color(uiColor: .systemBackground))
                }
                if case .disconnected(let error) = session.state {
                    DisconnectedBanner(error: error) { session.connect() }
                }
            }
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea(edges: .bottom))
        .navigationTitle(session.profile.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(session.profile.displayName).font(.headline)
                    Text(statusLine).font(.caption2).foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { fontSize = min(fontSize + 1, 24) } label: { Label("Larger Text", systemImage: "textformat.size.larger") }
                    Button { fontSize = max(fontSize - 1, 8) } label: { Label("Smaller Text", systemImage: "textformat.size.smaller") }
                    Divider()
                    Button { session.send(session.profile.herdr.attach() + "\r") } label: {
                        Label("Run herdr", systemImage: "rectangle.split.3x1")
                    }
                    if session.state.isLive {
                        Button(role: .destructive) { session.disconnect() } label: {
                            Label("Disconnect", systemImage: "xmark.circle")
                        }
                    } else {
                        Button { session.connect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { session.isVisible = true }
        .onDisappear { session.isVisible = false }
    }

    private var agentsTabTitle: String {
        let blocked = session.blockedCount
        return blocked > 0 ? "Agents (\(blocked) waiting)" : "Agents"
    }

    private var statusLine: String {
        switch session.state {
        case .idle: return "idle"
        case .connecting: return "connecting…"
        case .connected: return session.title.isEmpty ? session.profile.addressLabel : session.title
        case .disconnected: return "disconnected"
        }
    }
}

private struct DisconnectedBanner: View {
    let error: String?
    let reconnect: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                Text(error ?? "Disconnected").font(.subheadline).multilineTextAlignment(.center)
                Button("Reconnect", action: reconnect).buttonStyle(.borderedProminent)
                Text("herdr keeps your agents running on the server; reconnecting reattaches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding()
        }
    }
}
