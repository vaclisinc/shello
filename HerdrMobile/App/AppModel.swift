import Foundation
import HerdrKit
import SwiftUI

/// App-wide state: stores, live sessions and the host-key prompt.
@MainActor
final class AppModel: ObservableObject {
    let hosts = HostStore()
    let keys = KeyStore()
    let knownHosts = KnownHostsStore.defaultStore()

    @Published private(set) var sessions: [UUID: TerminalSession] = [:]
    @Published var hostKeyPrompt: HostKeyChallenge?
    private var hostKeyContinuation: CheckedContinuation<Bool, Never>?

    func session(for host: HostProfile) -> TerminalSession {
        if let existing = sessions[host.id] { return existing }
        let session = TerminalSession(profile: host, app: self)
        sessions[host.id] = session
        return session
    }

    func existingSession(for host: HostProfile) -> TerminalSession? {
        sessions[host.id]
    }

    func close(_ host: HostProfile) {
        sessions[host.id]?.disconnect()
        sessions[host.id] = nil
    }

    func delete(_ host: HostProfile) {
        close(host)
        knownHosts.forget(host.knownHostsKey)
        hosts.delete(host)
    }

    func sceneBecameActive() {
        for session in sessions.values {
            session.reconnectIfNeeded()
        }
    }

    // MARK: Host keys

    /// Suspends the connecting task until the user trusts or rejects the key.
    func confirmHostKey(_ challenge: HostKeyChallenge) async -> Bool {
        // Only one prompt at a time; reject a second one rather than queueing.
        guard hostKeyContinuation == nil else { return false }
        return await withCheckedContinuation { continuation in
            hostKeyContinuation = continuation
            hostKeyPrompt = challenge
        }
    }

    func answerHostKey(_ trusted: Bool) {
        hostKeyContinuation?.resume(returning: trusted)
        hostKeyContinuation = nil
        hostKeyPrompt = nil
    }
}
