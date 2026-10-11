import Foundation
import Security

/// Small wrapper over generic-password Keychain items. Items never leave this device
/// and are unavailable until the first unlock after boot.
public struct Keychain: Sendable {
    public var service: String

    public init(service: String = "dev.herdr.mobile") {
        self.service = service
    }

    public enum KeychainError: Error, LocalizedError {
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .status(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "Keychain error \(status): \(message)"
            }
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func set(_ data: Data, for account: String) throws {
        let query = baseQuery(account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addStatus = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public func data(for account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    public func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    // MARK: Typed helpers

    public func setString(_ value: String, for account: String) throws {
        try set(Data(value.utf8), for: account)
    }

    public func string(for account: String) throws -> String? {
        try data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setCodable<T: Encodable>(_ value: T, for account: String) throws {
        try set(JSONEncoder().encode(value), for: account)
    }

    public func codable<T: Decodable>(_ type: T.Type, for account: String) throws -> T? {
        try data(for: account).map { try JSONDecoder().decode(type, from: $0) }
    }

    public static func passwordAccount(host: UUID) -> String { "password.\(host.uuidString)" }
    public static func privateKeyAccount(key: UUID) -> String { "privatekey.\(key.uuidString)" }
}
