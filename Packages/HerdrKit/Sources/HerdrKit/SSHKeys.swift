import Citadel
import Crypto
import Foundation

public enum SSHKeyError: Error, LocalizedError, Equatable {
    case notOpenSSHFormat
    case unsupportedKeyType(String)
    case wrongPassphrase

    public var errorDescription: String? {
        switch self {
        case .notOpenSSHFormat:
            return "Paste a private key in OpenSSH format (-----BEGIN OPENSSH PRIVATE KEY-----)."
        case .unsupportedKeyType(let type):
            return "Key type \(type) is not supported. Use an ed25519 or RSA key."
        case .wrongPassphrase:
            return "Could not decrypt the key. Check the passphrase."
        }
    }
}

/// Private key material as kept in the Keychain.
public enum StoredPrivateKey: Codable, Sendable, Equatable {
    /// An ed25519 key generated on device (32-byte seed).
    case ed25519Seed(Data)
    /// A pasted OpenSSH private key, re-parsed on every connect.
    case openSSH(pem: String, passphrase: String?)
}

/// Public metadata about a key, safe to show and to persist outside the Keychain.
public struct SSHKeyInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var keyType: String
    /// One-line OpenSSH public key, for `~/.ssh/authorized_keys`.
    public var publicKey: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, keyType: String, publicKey: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.keyType = keyType
        self.publicKey = publicKey
        self.createdAt = createdAt
    }

    public var fingerprint: String {
        SSHWire.fingerprint(openSSHPublicKey: publicKey) ?? ""
    }
}

public enum SSHKeyFactory {
    public static func generateEd25519(name: String) -> (SSHKeyInfo, StoredPrivateKey) {
        let key = Curve25519.Signing.PrivateKey()
        let comment = name.replacingOccurrences(of: " ", with: "-")
        let publicLine = SSHWire.ed25519PublicKeyLine(key.publicKey.rawRepresentation, comment: comment)
        return (SSHKeyInfo(name: name, keyType: "ssh-ed25519", publicKey: publicLine), .ed25519Seed(key.rawRepresentation))
    }

    /// Validates a pasted key (decrypting it once) and extracts its public half.
    public static func importOpenSSH(name: String, pem: String, passphrase: String?) throws -> (SSHKeyInfo, StoredPrivateKey) {
        let pem = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let blob = SSHWire.openSSHPublicKeyBlob(fromPrivateKeyPEM: pem),
              let type = SSHWire.keyType(ofPublicKeyBlob: blob) else {
            throw SSHKeyError.notOpenSSHFormat
        }
        let pass = (passphrase?.isEmpty ?? true) ? nil : passphrase
        let stored = StoredPrivateKey.openSSH(pem: pem, passphrase: pass)
        _ = try authenticationMethod(username: "probe", key: stored)
        let line = "\(type) \(blob.base64EncodedString()) \(name.replacingOccurrences(of: " ", with: "-"))"
        return (SSHKeyInfo(name: name, keyType: type, publicKey: line), stored)
    }

    public static func authenticationMethod(username: String, key: StoredPrivateKey) throws -> SSHAuthenticationMethod {
        switch key {
        case .ed25519Seed(let seed):
            return .ed25519(username: username, privateKey: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
        case .openSSH(let pem, let passphrase):
            guard let blob = SSHWire.openSSHPublicKeyBlob(fromPrivateKeyPEM: pem),
                  let type = SSHWire.keyType(ofPublicKeyBlob: blob) else {
                throw SSHKeyError.notOpenSSHFormat
            }
            let decryptionKey = passphrase.map { Data($0.utf8) }
            do {
                switch type {
                case "ssh-ed25519":
                    return .ed25519(username: username, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: decryptionKey))
                case "ssh-rsa":
                    return .rsa(username: username, privateKey: try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: decryptionKey))
                default:
                    throw SSHKeyError.unsupportedKeyType(type)
                }
            } catch let error as SSHKeyError {
                throw error
            } catch {
                throw SSHKeyError.wrongPassphrase
            }
        }
    }
}

/// Minimal SSH wire-format helpers (RFC 4251 strings) for public keys and fingerprints.
public enum SSHWire {
    static func appendString(_ bytes: Data, to data: inout Data) {
        var length = UInt32(bytes.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(bytes)
    }

    static func readString(_ data: Data, at offset: inout Int) -> Data? {
        guard offset + 4 <= data.count else { return nil }
        let start = data.startIndex + offset
        let length = data[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        guard length >= 0, offset + length <= data.count else { return nil }
        let bodyStart = data.startIndex + offset
        offset += length
        return Data(data[bodyStart..<bodyStart + length])
    }

    public static func ed25519PublicKeyLine(_ rawPublicKey: Data, comment: String) -> String {
        var blob = Data()
        appendString(Data("ssh-ed25519".utf8), to: &blob)
        appendString(rawPublicKey, to: &blob)
        let line = "ssh-ed25519 \(blob.base64EncodedString())"
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// The public key blob stored unencrypted inside an `openssh-key-v1` private key.
    public static func openSSHPublicKeyBlob(fromPrivateKeyPEM pem: String) -> Data? {
        let lines = pem.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              let endIndex = lines.firstIndex(of: "-----END OPENSSH PRIVATE KEY-----") else {
            return nil
        }
        guard let body = Data(base64Encoded: lines[1..<endIndex].joined()) else { return nil }
        let magic = Data("openssh-key-v1\0".utf8)
        guard body.count > magic.count, body.prefix(magic.count) == magic else { return nil }
        var offset = magic.count
        guard readString(body, at: &offset) != nil, // cipher
              readString(body, at: &offset) != nil, // kdf
              readString(body, at: &offset) != nil, // kdf options
              offset + 4 <= body.count else { return nil }
        let countStart = body.startIndex + offset
        let keyCount = body[countStart..<countStart + 4].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        guard keyCount >= 1 else { return nil }
        return readString(body, at: &offset)
    }

    public static func keyType(ofPublicKeyBlob blob: Data) -> String? {
        var offset = 0
        return readString(blob, at: &offset).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `SHA256:<base64>` like `ssh-keygen -lf`.
    public static func fingerprint(publicKeyBlob blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    public static func fingerprint(openSSHPublicKey line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return fingerprint(publicKeyBlob: blob)
    }
}
