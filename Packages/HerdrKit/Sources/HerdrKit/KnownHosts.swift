import Foundation
import NIOCore
import NIOSSH

/// What the user is asked to confirm before a host key is trusted.
public struct HostKeyChallenge: Sendable, Identifiable {
    public enum Reason: Sendable {
        case firstConnection
        /// The server presented a different key than the one saved. Possible MITM.
        case changed(previousFingerprint: String)
    }

    public var id: String { host + fingerprint }
    public var host: String
    public var keyType: String
    public var fingerprint: String
    public var reason: Reason
}

/// Trust-on-first-use host key store, persisted as JSON.
public final class KnownHostsStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var entries: [String: String]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    public static func defaultStore() -> KnownHostsStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return KnownHostsStore(url: dir.appendingPathComponent("known_hosts.json"))
    }

    public func key(for host: String) -> String? {
        lock.withLock { entries[host] }
    }

    public func trust(_ openSSHKey: String, for host: String) {
        lock.withLock {
            entries[host] = openSSHKey
            if let data = try? JSONEncoder().encode(entries) {
                try? data.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
    }

    public func forget(_ host: String) {
        lock.withLock {
            entries[host] = nil
            if let data = try? JSONEncoder().encode(entries) {
                try? data.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
    }
}

public struct HostKeyRejected: Error, LocalizedError {
    public var errorDescription: String? { "The host key was not trusted, so the connection was closed." }
}

/// Validates server host keys against `KnownHostsStore`, asking the user for
/// unknown or changed keys.
public final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    public typealias Confirm = @Sendable (HostKeyChallenge) async -> Bool

    private let host: String
    private let store: KnownHostsStore
    private let confirm: Confirm

    public init(host: String, store: KnownHostsStore, confirm: @escaping Confirm) {
        self.host = host
        self.store = store
        self.confirm = confirm
    }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: hostKey)
        let presented = Self.normalize(line)
        let fingerprint = SSHWire.fingerprint(openSSHPublicKey: presented) ?? presented
        let keyType = String(presented.split(separator: " ").first ?? "")

        let reason: HostKeyChallenge.Reason
        if let saved = store.key(for: host) {
            if Self.normalize(saved) == presented {
                validationCompletePromise.succeed(())
                return
            }
            reason = .changed(previousFingerprint: SSHWire.fingerprint(openSSHPublicKey: saved) ?? "?")
        } else {
            reason = .firstConnection
        }

        let challenge = HostKeyChallenge(host: host, keyType: keyType, fingerprint: fingerprint, reason: reason)
        let store = self.store
        let host = self.host
        let confirm = self.confirm
        Task {
            if await confirm(challenge) {
                store.trust(presented, for: host)
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyRejected())
            }
        }
    }

    /// `type base64` without any trailing comment.
    static func normalize(_ line: String) -> String {
        line.split(separator: " ").prefix(2).joined(separator: " ")
    }
}
