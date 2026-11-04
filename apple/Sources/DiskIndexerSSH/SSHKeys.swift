import CryptoKit
import Foundation
import NIOSSH
import Security

/// This device's SSH key: an Ed25519 key kept in the Keychain, created on
/// first use. Its public half goes in the server's ~/.ssh/authorized_keys.
public enum SSHKeys {
    static let service = "com.virajchitnis.diskindexer.ssh"

    /// The key stored under account, creating and saving one if there's none.
    public static func loadOrCreate(account: String = "default") throws -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.rawRepresentation,
            // Readable after the first unlock, never synced or backed up off
            // this device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return key
    }

    /// "ssh-ed25519 AAAA… comment", for authorized_keys.
    public static func openSSHPublicKey(_ key: Curve25519.Signing.PrivateKey, comment: String) -> String {
        String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) + " " + comment
    }
}

/// Trusted host keys in UserDefaults. They're public, so the Keychain isn't
/// needed.
public final class DefaultsHostKeyStore: HostKeyStore, @unchecked Sendable {
    let defaults: UserDefaults
    let key = "trustedHostKeys"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func trusted(for address: String) -> String? {
        (defaults.dictionary(forKey: key) as? [String: String])?[address]
    }

    public func trust(_ hostKey: String, for address: String) {
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[address] = hostKey
        defaults.set(all, forKey: key)
    }
}

/// Host keys held in memory, for tests.
public final class MemoryHostKeyStore: HostKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    public init() {}

    public func trusted(for address: String) -> String? { lock.withLock { keys[address] } }
    public func trust(_ hostKey: String, for address: String) { lock.withLock { keys[address] = hostKey } }
}
