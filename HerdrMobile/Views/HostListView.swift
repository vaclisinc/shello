import HerdrKit
import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var hosts: HostStore
    @State private var path: [UUID] = []
    @State private var editing: HostProfile?
    @State private var showingKeys = false
    @ObservedObject private var notifications = NotificationDelegate.shared

    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .light

    var body: some View {
        NavigationStack(path: $path) {
            List {
                header.cardRow()
                if hosts.hosts.isEmpty {
                    emptyState.cardRow()
                } else {
                    SectionLabel("Hosts")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 0, trailing: 16))
                }
                ForEach(hosts.hosts) { host in
                    Button { open(host) } label: {
                        HostRow(host: host, session: app.sessions[host.id])
                    }
                    .buttonStyle(.plain)
                    .cardRow()
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { app.delete(host) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { editing = host } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(Theme.yellow)
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
            .listStyle(.plain)
            .paperScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showingKeys = true } label: { Label("SSH Keys", systemImage: "key") }
                        Picker(selection: $appearance) {
                            ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                        } label: {
                            Label("Appearance", systemImage: "circle.lefthalf.filled")
                        }
                        .pickerStyle(.menu)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
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
            .onChange(of: notifications.route, initial: true) { _, route in
                guard let route, let host = hosts.hosts.first(where: { $0.id == route.host }) else { return }
                notifications.route = nil
                let session = app.session(for: host)
                session.requestedAgentPane = route.pane
                if !session.state.isLive { session.connect() }
                path = [host.id]
            }
            .sheet(item: $editing) { host in
                HostEditorView(host: host)
            }
            .sheet(isPresented: $showingKeys) {
                NavigationStack { KeysView() }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image("BrandMark")
                .resizable()
                .frame(width: 56, height: 56)
                .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.line))
            VStack(alignment: .leading, spacing: 4) {
                Text("SHELLO")
                    .font(Theme.mono(30, .heavy))
                    .foregroundStyle(Theme.ink)
                Text("Say hello to your terminal.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SESSIONS THAT NEVER HANG UP")
                .font(Theme.mono(16, .heavy))
                .foregroundStyle(Theme.ink)
            Text("Connect over SSH to herdr, tmux or any shell. Your work keeps running on the server, and Shello taps you when an agent needs approval or finishes.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            Button("Add a host") { editing = HostProfile() }
                .buttonStyle(BlockButtonStyle())
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
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
            Rectangle()
                .fill(dotColor)
                .frame(width: 12, height: 12)
                .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(host.displayName)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(host.addressLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                Text(host.startup.rawValue.uppercased())
                    .font(Theme.mono(10))
                    .tracking(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(Rectangle().strokeBorder(Theme.muted, lineWidth: 1))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            }
            Spacer()
            if working > 0 {
                Label("\(working)", systemImage: "gearshape.2")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.sky)
                    .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
            }
            if blocked > 0 {
                Text("\(blocked)")
                    .font(Theme.mono(12))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.coral)
                    .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: 1.5))
                    .foregroundStyle(Theme.onAccent)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.bold())
                .foregroundStyle(Theme.muted)
        }
        .padding(14)
        .card()
    }

    private var dotColor: Color {
        switch status {
        case .connected: return Theme.mint
        case .connecting: return Theme.yellow
        case .disconnected(let error): return error == nil ? Theme.card : Theme.coral
        case .idle, .none: return Theme.card
        }
    }
}
