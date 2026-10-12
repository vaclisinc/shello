import HerdrKit
import SwiftUI

struct SessionView: View {
    @ObservedObject var session: TerminalSession
    // New key so everyone starts from the smaller, per-device default.
    @AppStorage("terminalFontSize.v2") private var fontSize: Double = TerminalHostView.defaultFontSize
    @AppStorage("didShowTerminalTips.v2") private var didShowTips = false
    @State private var showingTips = false
    @EnvironmentObject private var app: AppModel
    @AppStorage(BackgroundLocation.enabledKey) private var keepAlive = false
    @State private var tab: Tab = .terminal

    enum Tab: Hashable { case terminal, agents }

    init(session: TerminalSession) {
        self.session = session
    }

    var body: some View {
        VStack(spacing: 0) {
            // The Agents inbox only exists for herdr hosts; tmux and plain shells are terminal-only.
            if session.profile.startup == .herdr {
                BlockSegmented(selection: $tab, options: [(.terminal, "Terminal"), (.agents, agentsTabTitle)])
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.paper)
            }

            ZStack {
                // Keep the terminal alive (and its scrollback) while the agents tab is shown.
                TerminalHostView(session: session, fontSize: fontSize, isActive: tab == .terminal) { fontSize = $0 }
                    .opacity(tab == .terminal ? 1 : 0)
                    .allowsHitTesting(tab == .terminal)
                if tab == .agents {
                    AgentsView(session: session) { tab = .terminal }
                }
                if case .disconnected(let error) = session.state {
                    DisconnectedBanner(error: error) { session.connect() }
                }
                if showingTips && tab == .terminal {
                    TerminalTips {
                        showingTips = false
                        didShowTips = true
                    }
                }
            }
        }
        .background(TerminalPalette.background.ignoresSafeArea(edges: .bottom))
        .toolbarBackground(Theme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle(session.profile.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(session.profile.displayName).font(.headline).foregroundStyle(Theme.ink)
                    Text(statusLine).font(Theme.mono(10, .medium)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { fontSize = min(fontSize + 1, TerminalHostView.fontSizeRange.upperBound) } label: { Label("Larger Text", systemImage: "textformat.size.larger") }
                    Button { fontSize = max(fontSize - 1, TerminalHostView.fontSizeRange.lowerBound) } label: { Label("Smaller Text", systemImage: "textformat.size.smaller") }
                    Toggle(isOn: $keepAlive) { Label("Stay Connected in Background", systemImage: "location") }
                    Button { showingTips = true } label: { Label("Tips", systemImage: "questionmark.circle") }
                    Divider()
                    if let command = session.profile.startupCommand {
                        Button { session.send(command + "\r") } label: {
                            Label(startupLabel, systemImage: "rectangle.split.3x1")
                        }
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
        // A tapped notification lands in the live terminal, on that agent's pane.
        .task(id: session.requestedAgentPane) {
            guard session.requestedAgentPane != nil else { return }
            tab = .terminal
            await session.focusRequestedAgent()
        }
        .onChange(of: keepAlive) { _, _ in app.updateBackgroundKeepAlive() }
        .onAppear {
            session.isVisible = true
            #if DEBUG
            if ReadmeDemo.isOn {
                tab = .agents
                return
            }
            #endif
            if !didShowTips { showingTips = true }
        }
        .onDisappear { session.isVisible = false }
    }

    private var startupLabel: String {
        switch session.profile.startup {
        case .herdr: return "Run herdr"
        case .tmux: return "Attach tmux"
        case .shell, .custom: return "Run Startup Command"
        }
    }

    private var agentsTabTitle: String {
        let blocked = session.blockedCount
        return blocked > 0 ? "Agents · \(blocked) waiting" : "Agents"
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

/// First-run hints for gestures that aren't discoverable on their own.
private struct TerminalTips: View {
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 16) {
                Text("HELLO, TERMINAL").font(Theme.mono(18, .heavy)).foregroundStyle(Theme.ink)
                tip("arrow.up.left.and.arrow.down.right", "Pinch with two fingers to make the text bigger or smaller.")
                tip("hand.draw", "Swipe the key bar above the keyboard left and right for esc, ctrl, alt, ⇧tab, arrows and other keys the phone keyboard can't type.")
                tip("location", "Want agent notifications while Shello is in the background? Turn on “Stay Connected in Background” in the ⋯ menu. iOS will ask for location access: it's only used to keep the app awake (coarse, no GPS, never stored), and costs some battery.")
                tip("ellipsis.circle", "Find these tips again in the ⋯ menu.")
                Button("Got it", action: dismiss)
                    .buttonStyle(BlockButtonStyle())
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
            .card()
            .padding(24)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 30, height: 30)
                .background(Theme.yellow)
                .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
            Text(text).font(.subheadline).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DisconnectedBanner: View {
    let error: String?
    let reconnect: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Text((error ?? "Disconnected").uppercased())
                    .font(Theme.mono(13, .heavy))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Button("Reconnect", action: reconnect).buttonStyle(BlockButtonStyle())
                Text("Your session keeps running on the server; reconnecting picks up where you left off.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .card()
            .padding()
        }
    }
}
