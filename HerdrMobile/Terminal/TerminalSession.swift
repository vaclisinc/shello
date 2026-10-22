import Foundation
import HerdrKit
import SwiftTerm
import UIKit

/// One live connection to a host: the interactive PTY (usually running the
/// herdr TUI) plus a background poller that watches herdr's agent states.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case disconnected(String?)

        var isLive: Bool { self == .connecting || self == .connected }
    }

    private enum Input {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    nonisolated let id: UUID
    @Published private(set) var profile: HostProfile
    @Published private(set) var state: State = .idle {
        didSet { if state != oldValue { app?.sessionsChanged() } }
    }
    @Published private(set) var title: String = ""
    @Published private(set) var snapshot: SessionSnapshot? {
        didSet { if snapshot != oldValue { app?.sessionsChanged() } }
    }

    #if DEBUG
    /// Lets the UI harness show screens without a server.
    func debugSetSnapshot(_ snapshot: SessionSnapshot) { self.snapshot = snapshot }
    #endif
    /// Pane of an agent to bring up in the live terminal (set when a notification is tapped).
    @Published var requestedAgentPane: String?

    /// Switches herdr to the requested agent's pane once the connection and agent list are
    /// back (a tap may have woken or relaunched the app), so the live TUI shows that agent.
    func focusRequestedAgent() async {
        guard let pane = requestedAgentPane else { return }
        for _ in 0..<40 {
            if Task.isCancelled { return }
            if state == .connected, let remote = herdr, let agent = snapshot?.agents.first(where: { $0.paneId == pane }) {
                requestedAgentPane = nil
                try? await remote.focus(agent)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        requestedAgentPane = nil
    }
    @Published private(set) var monitorError: String?
    /// True while the session screen is on screen; alerts become haptics instead of banners.
    var isVisible = false

    private weak var app: AppModel?
    private(set) var connection: SSHConnection?
    private var shellTask: Task<Void, Never>?
    /// Bumped on every connect and teardown, so a superseded attempt can't touch the current one.
    private var attempt = 0
    private var monitorTask: Task<Void, Never>?
    private var input: AsyncStream<Input>.Continuation?
    private var cols = 80
    private var rows = 24
    /// Output that arrived before the terminal view was attached.
    private var backlog: [UInt8] = []
    private weak var terminalView: TerminalView?
    /// The user wants this session up; drives auto-reconnect when returning to the foreground.
    private(set) var wantsConnection = false

    init(profile: HostProfile, app: AppModel) {
        self.id = profile.id
        self.profile = profile
        self.app = app
    }

    var herdr: HerdrRemote? { connection.map(HerdrRemote.init) }

    var blockedCount: Int { snapshot?.blockedCount ?? 0 }

    // MARK: Lifecycle

    func connect() {
        guard !state.isLive, let app else { return }
        // Don't leave the previous attempt (and its herdr client) running on the server.
        teardown()
        #if DEBUG
        if ReadmeDemo.isOn {
            state = .connected
            return
        }
        #endif
        wantsConnection = true
        app.updateBackgroundKeepAlive()
        state = .connecting
        if let updated = app.hosts.hosts.first(where: { $0.id == profile.id }) {
            profile = updated
        }
        let knownHosts = app.knownHosts
        // Built outside the Task: nesting this closure inside it crashes the
        // Swift 6.1 optimizer (ClosureLifetimeFixup).
        let confirm: TOFUHostKeyValidator.Confirm = { [weak app] challenge in
            await app?.confirmHostKey(challenge) ?? false
        }
        let attempt = self.attempt
        shellTask = Task { [weak self] in
            await self?.establish(attempt: attempt, knownHosts: knownHosts, confirm: confirm)
        }
    }

    private func establish(attempt: Int, knownHosts: KnownHostsStore, confirm: @escaping TOFUHostKeyValidator.Confirm) async {
        do {
            let connection = try await SSHConnection.connect(
                profile: profile,
                knownHosts: knownHosts,
                confirmHostKey: confirm
            )
            guard !Task.isCancelled, attempt == self.attempt else {
                await connection.close()
                return
            }
            self.connection = connection
            state = .connected
            startMonitor()
            try await runShell(on: connection)
            finish(nil, attempt: attempt)
        } catch is CancellationError {
            finish(nil, attempt: attempt)
        } catch {
            finish(error.localizedDescription, attempt: attempt)
        }
    }

    func disconnect() {
        wantsConnection = false
        app?.updateBackgroundKeepAlive()
        finish(nil, attempt: attempt)
    }

    func reconnectIfNeeded() {
        guard wantsConnection else { return }
        if case .disconnected = state { connect() }
        if state == .connected, connection?.isConnected == false {
            finish("Connection lost", attempt: attempt)
            connect()
        }
    }

    /// Stops the current attempt for good: its shell, poller and SSH connection.
    private func teardown() {
        attempt += 1
        shellTask?.cancel()
        shellTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        input?.finish()
        input = nil
        if let connection {
            Task { await connection.close() }
        }
        connection = nil
    }

    /// Ignored when `attempt` was superseded, so a stale shell ending can't kill a newer connection.
    private func finish(_ error: String?, attempt: Int) {
        guard attempt == self.attempt, state.isLive else { return }
        teardown()
        state = .disconnected(error)
        // Kept alive in the background (e.g. the network changed): retry instead of waiting for the foreground.
        if wantsConnection, error != nil, UIApplication.shared.applicationState == .background, BackgroundLocation.isEnabled {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.reconnectIfNeeded()
            }
        }
        let message = error.map { "\r\n\u{1b}[31m[\($0)]\u{1b}[0m\r\n" } ?? "\r\n\u{1b}[90m[disconnected]\u{1b}[0m\r\n"
        feed(Array(message.utf8))
    }

    // MARK: Shell

    private func runShell(on connection: SSHConnection) async throws {
        let (stream, continuation) = AsyncStream<Input>.makeStream()
        input = continuation
        let profile = self.profile
        let startupCommand = profile.startupCommand

        try await connection.withShell(cols: cols, rows: rows) { output, writer in
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Single writer keeps keystrokes and resizes in order.
                group.addTask {
                    if let startupCommand {
                        try await writer.write(Array("\(startupCommand)\r".utf8))
                    }
                    for await event in stream {
                        switch event {
                        case .bytes(let bytes):
                            try await writer.write(bytes)
                        case .resize(let cols, let rows):
                            try await writer.resize(cols: cols, rows: rows)
                        }
                    }
                }
                group.addTask {
                    for try await bytes in output {
                        await self.feed(bytes)
                    }
                }
                // When the shell exits, stop the writer too.
                _ = try await group.next()
                group.cancelAll()
            }
        }
    }

    // MARK: Terminal plumbing

    func attach(view: TerminalView) {
        terminalView = view
        if !backlog.isEmpty {
            view.feed(byteArray: backlog[...])
            backlog.removeAll()
        }
    }

    private func feed(_ bytes: [UInt8]) {
        if let terminalView {
            terminalView.feed(byteArray: bytes[...])
        } else {
            backlog.append(contentsOf: bytes)
            if backlog.count > 1_000_000 { backlog.removeFirst(backlog.count - 1_000_000) }
        }
    }

    func send(_ bytes: [UInt8]) {
        input?.yield(.bytes(bytes))
    }

    func send(_ text: String) {
        send(Array(text.utf8))
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        input?.yield(.resize(cols: cols, rows: rows))
    }

    func setTitle(_ title: String) {
        self.title = title
    }

    // MARK: Agent monitor

    private func startMonitor() {
        monitorTask?.cancel()
        guard profile.watchesAgents else { return }
        monitorTask = Task { [weak self] in
            // Give the TUI a moment to start its server on first launch.
            try? await Task.sleep(for: .seconds(1.5))
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.pollOnce()
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// Returns how long to wait before the next poll.
    private func pollOnce() async -> Duration {
        guard let remote = herdr else { return .seconds(5) }
        do {
            let next = try await remote.snapshot()
            let alerts = AgentTransitions.alerts(from: snapshot, to: next)
            snapshot = next
            monitorError = nil
            for alert in alerts {
                Notifier.post(alert, host: profile, sessionVisible: isVisible)
            }
            return UIApplication.shared.applicationState == .active ? .seconds(2) : .seconds(5)
        } catch HerdrResponseError.herdrNotFound {
            monitorError = HerdrResponseError.herdrNotFound.localizedDescription
            return .seconds(30)
        } catch let error as HerdrAPIError where error.code == "server_not_running" {
            monitorError = "herdr is not running on this host yet."
            snapshot = nil
            return .seconds(5)
        } catch {
            monitorError = error.localizedDescription
            return .seconds(5)
        }
    }

    /// Refresh immediately (pull to refresh, after sending input).
    func refreshAgents() async {
        _ = await pollOnce()
    }
}
