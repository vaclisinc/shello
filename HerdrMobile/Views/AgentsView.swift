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
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            if !session.profile.monitorAgents {
                Section {
                    Text("Agent monitoring is off for this host. Turn on “Watch agents & notify” in the host settings.")
                        .foregroundStyle(.secondary)
                }
            } else if let snapshot = session.snapshot {
                if snapshot.agents.isEmpty {
                    Section {
                        Text("No agents detected. Start Claude Code, Codex or another agent in a herdr pane.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(snapshot.agentsByUrgency) { agent in
                            Button { selected = agent } label: {
                                AgentRow(agent: agent, workspace: snapshot.workspace(agent.workspaceId))
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        Text("herdr \(snapshot.version)")
                    }
                }
            } else if session.monitorError == nil {
                Section {
                    HStack {
                        ProgressView()
                        Text("Waiting for herdr…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .refreshable { await session.refreshAgents() }
        .sheet(item: $selected) { agent in
            AgentDetailView(session: session, agentID: agent.id) {
                selected = nil
                showTerminal()
            }
        }
    }
}

struct AgentRow: View {
    let agent: AgentInfo
    let workspace: WorkspaceInfo?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusBadge(status: agent.agentStatus)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(agent.displayName).font(.headline)
                    Spacer()
                    Text(agent.kindLabel).font(.caption).foregroundStyle(.secondary)
                }
                if let subtitle = agent.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let workspace {
                    Text("\(workspace.label) · \(agent.paneId)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: status == .working)
            .frame(width: 28)
            .accessibilityLabel(status.rawValue)
    }

    private var symbol: String {
        switch status {
        case .blocked: return "hand.raised.fill"
        case .done: return "checkmark.circle.fill"
        case .working: return "circle.dotted.circle"
        case .idle: return "circle"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch status {
        case .blocked: return .orange
        case .done: return .green
        case .working: return .blue
        case .idle: return .secondary
        case .unknown: return .gray
        }
    }
}
