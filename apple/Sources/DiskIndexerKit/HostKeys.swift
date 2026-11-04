import Foundation

/// A server whose SSH host key isn't trusted yet (`unknown`) or no longer
/// matches the one trusted for its address (`changed`). The app shows the
/// fingerprint and lets the user trust it, instead of sending them to
/// Terminal.
public struct HostKeyProblem: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Never connected to this address before.
        case unknown
        /// A different key was trusted for this address. Either the server
        /// was reinstalled, the address now belongs to another machine, or
        /// someone is intercepting the connection.
        case changed
    }

    /// A line in a known_hosts file.
    public struct Entry: Sendable, Equatable {
        public var file: String
        public var line: Int
    }

    /// The address as the user entered it.
    public var address: String
    public var kind: Kind
    /// "ED25519", "ECDSA" or "RSA".
    public var keyType: String
    /// The key the server presents now, e.g. "SHA256:/MZv…".
    public var fingerprint: String
    /// For `changed`: the trusted entry that conflicts with it.
    public var offending: Entry?
    /// For `changed`: the key that entry holds.
    public var previousFingerprint: String?
    /// The server's other addresses whose trusted key is this same key, which
    /// is good evidence that the address now reaches the same machine.
    public var matchingAddresses: [String] = []

    public init(address: String, kind: Kind, keyType: String, fingerprint: String,
                offending: Entry? = nil, previousFingerprint: String? = nil, matchingAddresses: [String] = []) {
        self.address = address
        self.kind = kind
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.offending = offending
        self.previousFingerprint = previousFingerprint
        self.matchingAddresses = matchingAddresses
    }

    /// Reads the output of `ssh -v -o BatchMode=yes <address> true` that
    /// failed host key verification. nil if it doesn't show the server's key
    /// (e.g. the connection failed earlier).
    public static func parse(_ log: String, address: String) -> HostKeyProblem? {
        var algorithm: String?
        var fingerprint: String?
        var offending: Entry?
        for raw in log.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: "Server host key: ") {
                let parts = line[r.upperBound...].split(separator: " ")
                if parts.count >= 2 {
                    algorithm = String(parts[0])
                    fingerprint = String(parts[1])
                }
            } else if line.hasPrefix("Offending "), let r = line.range(of: " key in ") {
                // "Offending ED25519 key in /Users/me/.ssh/known_hosts:32"
                let location = line[r.upperBound...]
                if let colon = location.lastIndex(of: ":"), let n = Int(location[location.index(after: colon)...]) {
                    offending = Entry(file: String(location[..<colon]), line: n)
                }
            }
        }
        guard let algorithm, let fingerprint else { return nil }
        let changed = offending != nil || log.contains("REMOTE HOST IDENTIFICATION HAS CHANGED")
        return HostKeyProblem(address: address, kind: changed ? .changed : .unknown,
                              keyType: keyTypeName(algorithm), fingerprint: fingerprint, offending: offending)
    }

    /// "ssh-ed25519" → "ED25519", the name ssh uses in its messages.
    public static func keyTypeName(_ algorithm: String) -> String {
        switch algorithm {
        case let a where a.contains("ed25519"): return "ED25519"
        case let a where a.hasPrefix("ecdsa") || a.contains("ecdsa"): return "ECDSA"
        case let a where a.contains("rsa"): return "RSA"
        default: return algorithm.uppercased()
        }
    }

    /// One line for the error screen, in place of ssh's banner.
    public var summary: String {
        switch kind {
        case .unknown:
            return "\(ThisDevice.sentenceName) hasn\u{2019}t connected to \(address) before, so it can\u{2019}t yet tell whether the server is the one you expect."
        case .changed:
            if !matchingAddresses.isEmpty {
                return "\(address) now has a different host key than the one \(ThisDevice.name) trusted for it, but it\u{2019}s the key you already trust for \(matchingAddresses.joined(separator: ", "))."
            }
            return "\(address)\u{2019}s host key has changed since \(ThisDevice.name) last connected. The server may have been reinstalled, the address may now belong to another machine, or someone may be intercepting the connection."
        }
    }

    /// A changed key needs a second confirmation unless another address of
    /// the same server already vouches for it.
    public var needsConfirmation: Bool { kind == .changed && matchingAddresses.isEmpty }
}

/// A transport that can trust a server's host key itself (the SSH transport).
/// AppModel offers it when a connect fails with a HostKeyProblem.
public protocol HostKeyTrusting: AnyObject {
    /// Trusts the key `problem` describes, replacing the conflicting entry for
    /// a changed key. Throws if the server now presents any other key.
    func trustHostKey(_ problem: HostKeyProblem) async throws
}
