import HerdrKit
import SwiftUI

/// Inbox of herdr agents on one host, most urgent first.
struct AgentsView: View {
    @ObservedObject var session: TerminalSession
    var showTerminal: () -> Void
    @State private var selected: AgentInfo?

    init(session: TerminalSession, showTerminal: @escaping () -> Void) {
        self.session = session
        self.showTerminal = showTerminal
    }

    var body: some View {
        List {
            if let error = session.monitorError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.onAccent)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(fill: Theme.coral, shadow: 3)
                    .cardRow()
            }

            if !session.profile.watchesAgents {
                note("Agent monitoring is off for this host. Turn on “Watch agents & notify” in the host settings.")
            } else if let snapshot = session.snapshot {
                if snapshot.agents.isEmpty {
                    note("No agents yet. Start Claude Code, Codex or another agent in a herdr pane.")
                } else {
                    SectionLabel(snapshot.version.isEmpty ? "Agents" : "Agents · herdr \(snapshot.version)")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
                    ForEach(snapshot.agentsByUrgency) { agent in
                        Button { selected = agent } label: {
                            AgentRow(agent: agent, title: snapshot.displayName(for: agent))
                        }
                        .buttonStyle(.plain)
                        .cardRow()
                    }
                }
            } else if session.monitorError == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Waiting for herdr…").font(.subheadline).foregroundStyle(Theme.muted)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .cardRow()
            }
        }
        .listStyle(.plain)
        .paperScreen()
        .refreshable { await session.refreshAgents() }
        #if DEBUG
        .onAppear {
            if ReadmeDemo.opensChat { selected = session.snapshot?.agentsByUrgency.first { $0.agentStatus == .working } }
        }
        #endif
        .sheet(item: $selected) { agent in
            AgentDetailView(session: session, agentID: agent.id) {
                selected = nil
                showTerminal()
            }
            // A fresh view (and transcript state) for every agent.
            .id(agent.id)
        }
    }
}

extension AgentsView {
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.muted)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .cardRow()
    }
}

struct AgentRow: View {
    let agent: AgentInfo
    let title: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusBadge(status: agent.agentStatus)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(agent.kindLabel.uppercased())
                        .font(Theme.mono(10))
                        .tracking(1)
                        .foregroundStyle(Theme.muted)
                }
                if let subtitle = agent.subtitle {
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                Text(agent.agentStatus.rawValue.uppercased())
                    .font(Theme.mono(10))
                    .tracking(1)
                    .foregroundStyle(Theme.ink)
            }
        }
        .padding(14)
        .card(fill: agent.agentStatus == .blocked ? Theme.coralTint : Theme.card)
    }
}

struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(Theme.onAccent)
            .symbolEffect(.pulse, isActive: status == .working)
            .frame(width: 28, height: 28)
            .background(color)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
            .accessibilityLabel(status.rawValue)
    }

    private var symbol: String {
        switch status {
        case .blocked: return "hand.raised.fill"
        case .done: return "checkmark"
        case .working: return "ellipsis"
        case .idle: return "pause.fill"
        case .unknown: return "questionmark"
        }
    }

    var color: Color {
        switch status {
        case .blocked: return Theme.coral
        case .done: return Theme.mint
        case .working: return Theme.sky
        case .idle: return Color(hex: 0xE4DED6)
        case .unknown: return Color(hex: 0xC9C4BD)
        }
    }
}
