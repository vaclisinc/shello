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
    @Published private(set) var state: State = .idle
    @Published private(set) var title: String = ""
    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var monitorError: String?
    /// True while the session screen is on screen; alerts become haptics instead of banners.
    var isVisible = false

    private weak var app: AppModel?
    private(set) var connection: SSHConnection?
    private var shellTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var input: AsyncStream<Input>.Continuation?
    private var cols = 80
    private var rows = 24
    /// Output that arrived before the terminal view was attached.
    private var backlog: [UInt8] = []
    private weak var terminalView: TerminalView?
    /// The user wants this session up; drives auto-reconnect when returning to the foreground.
    private var wantsConnection = false

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
        wantsConnection = true
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
        shellTask = Task { [weak self] in
            await self?.establish(knownHosts: knownHosts, confirm: confirm)
        }
    }

    private func establish(knownHosts: KnownHostsStore, confirm: @escaping TOFUHostKeyValidator.Confirm) async {
        do {
            let connection = try await SSHConnection.connect(
                profile: profile,
                knownHosts: knownHosts,
                confirmHostKey: confirm
            )
            guard !Task.isCancelled else {
                await connection.close()
                return
            }
            self.connection = connection
            state = .connected
            startMonitor()
            try await runShell(on: connection)
            finish(nil)
        } catch is CancellationError {
            finish(nil)
        } catch {
            finish(error.localizedDescription)
        }
    }

    func disconnect() {
        wantsConnection = false
        shellTask?.cancel()
        monitorTask?.cancel()
        let connection = self.connection
        Task { await connection?.close() }
        finish(nil)
    }

    func reconnectIfNeeded() {
        guard wantsConnection else { return }
        if case .disconnected = state { connect() }
        if state == .connected, connection?.isConnected == false {
            finish("Connection lost")
            connect()
        }
    }

    private func finish(_ error: String?) {
        guard state.isLive else { return }
        monitorTask?.cancel()
        monitorTask = nil
        input?.finish()
        input = nil
        connection = nil
        state = .disconnected(error)
        let message = error.map { "\r\n\u{1b}[31m[\($0)]\u{1b}[0m\r\n" } ?? "\r\n\u{1b}[90m[disconnected]\u{1b}[0m\r\n"
        feed(Array(message.utf8))
    }

    // MARK: Shell

    private func runShell(on connection: SSHConnection) async throws {
        let (stream, continuation) = AsyncStream<Input>.makeStream()
        input = continuation
        let profile = self.profile
        let shouldAttachHerdr = profile.autoAttachHerdr

        try await connection.withShell(cols: cols, rows: rows) { output, writer in
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Single writer keeps keystrokes and resizes in order.
                group.addTask {
                    if shouldAttachHerdr {
                        try await writer.write(Array("\(profile.herdr.attach())\r".utf8))
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
        guard profile.monitorAgents else { return }
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
