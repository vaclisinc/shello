import Foundation
import HerdrKit

/// Small JSON-on-disk persistence for non-secret app data.
enum DiskStore {
    static func url(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(name), options: [.atomic, .completeFileProtection])
    }
}

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [HostProfile]
    private let keychain = Keychain()

    init() {
        hosts = DiskStore.load([HostProfile].self, from: "hosts.json") ?? []
    }

    func save(_ host: HostProfile, password: String?) throws {
        if case .password = host.auth, let password, !password.isEmpty {
            try keychain.setString(password, for: Keychain.passwordAccount(host: host.id))
        }
        if case .key = host.auth {
            keychain.delete(Keychain.passwordAccount(host: host.id))
        }
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        persist()
    }

    func hasPassword(for host: HostProfile) -> Bool {
        (try? keychain.data(for: Keychain.passwordAccount(host: host.id))) != nil
    }

    func delete(_ host: HostProfile) {
        keychain.delete(Keychain.passwordAccount(host: host.id))
        hosts.removeAll { $0.id == host.id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        hosts.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        DiskStore.save(hosts, to: "hosts.json")
    }
}

@MainActor
final class KeyStore: ObservableObject {
    @Published private(set) var keys: [SSHKeyInfo]
    private let keychain = Keychain()

    init() {
        keys = DiskStore.load([SSHKeyInfo].self, from: "keys.json") ?? []
    }

    @discardableResult
    func generate(name: String) throws -> SSHKeyInfo {
        let (info, secret) = SSHKeyFactory.generateEd25519(name: name)
        try add(info, secret)
        return info
    }

    @discardableResult
    func importKey(name: String, pem: String, passphrase: String?) throws -> SSHKeyInfo {
        let (info, secret) = try SSHKeyFactory.importOpenSSH(name: name, pem: pem, passphrase: passphrase)
        try add(info, secret)
        return info
    }

    func delete(_ key: SSHKeyInfo) {
        keychain.delete(Keychain.privateKeyAccount(key: key.id))
        keys.removeAll { $0.id == key.id }
        DiskStore.save(keys, to: "keys.json")
    }

    func key(_ id: UUID) -> SSHKeyInfo? {
        keys.first { $0.id == id }
    }

    private func add(_ info: SSHKeyInfo, _ secret: StoredPrivateKey) throws {
        try keychain.setCodable(secret, for: Keychain.privateKeyAccount(key: info.id))
        keys.append(info)
        DiskStore.save(keys, to: "keys.json")
    }
}
