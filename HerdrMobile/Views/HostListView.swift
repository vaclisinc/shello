import HerdrKit
import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var hosts: HostStore
    @State private var path: [UUID] = []
    @State private var editing: HostProfile?
    @State private var showingKeys = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if hosts.hosts.isEmpty {
                    emptyState
                }
                ForEach(hosts.hosts) { host in
                    Button { open(host) } label: {
                        HostRow(host: host, session: app.sessions[host.id])
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { app.delete(host) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { editing = host } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button { editing = host } label: { Label("Edit", systemImage: "pencil") }
                        if app.sessions[host.id] != nil {
                            Button { app.close(host) } label: { Label("Disconnect", systemImage: "xmark.circle") }
                        }
                        Button(role: .destructive) { app.delete(host) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .onMove { hosts.move(from: $0, to: $1) }
            }
            .navigationTitle("Herdr")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingKeys = true } label: { Image(systemName: "key") }
                        .accessibilityLabel("SSH Keys")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = HostProfile() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add Host")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let session = app.sessions[id] {
                    SessionView(session: session)
                }
            }
            .sheet(item: $editing) { host in
                HostEditorView(host: host)
            }
            .sheet(isPresented: $showingKeys) {
                NavigationStack { KeysView() }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a host to get started").font(.headline)
            Text("Herdr connects over SSH, opens the herdr TUI and watches your coding agents. You'll get an alert when one needs your approval or finishes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Add Host") { editing = HostProfile() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    private func open(_ host: HostProfile) {
        let session = app.session(for: host)
        if !session.state.isLive { session.connect() }
        path.append(host.id)
    }
}

private struct HostRow: View {
    let host: HostProfile
    let session: TerminalSession?

    var body: some View {
        if let session {
            LiveHostRow(host: host, session: session)
        } else {
            HostRowContent(host: host, status: nil, blocked: 0, working: 0)
        }
    }
}

private struct LiveHostRow: View {
    let host: HostProfile
    @ObservedObject var session: TerminalSession

    var body: some View {
        HostRowContent(
            host: host,
            status: session.state,
            blocked: session.blockedCount,
            working: session.snapshot?.agents.filter { $0.agentStatus == .working }.count ?? 0
        )
    }
}

private struct HostRowContent: View {
    let host: HostProfile
    let status: TerminalSession.State?
    let blocked: Int
    let working: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(dotColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(.headline).foregroundStyle(.primary)
                Text(host.addressLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if working > 0 {
                Label("\(working)", systemImage: "gearshape.2")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            if blocked > 0 {
                Text("\(blocked)")
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.orange, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 4)
    }

    private var dotColor: Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected(let error): return error == nil ? .secondary : .red
        case .idle, .none: return .secondary
        }
    }
}
