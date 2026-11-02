import DiskIndexerKit
import Foundation

/// Host key checks for SSHTunnel. ssh itself stays in charge of known_hosts:
/// the app only reads what ssh reports, removes the one conflicting line the
/// user agreed to replace, and lets `StrictHostKeyChecking=accept-new` add the
/// new key in whatever format the user's ssh config asks for.
extension SSHTunnel: HostKeyTrusting {
    static let sshKeygen = "/usr/bin/ssh-keygen"

    /// Called when ssh refused `host`'s key: asks ssh (verbosely) what key the
    /// server presents and what it conflicts with, so the app can show it.
    func hostKeyFailure(host: String, stderr: String) async -> ConnectionFailure {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = ConnectionFailure("""
            \(host)\u{2019}s host key isn\u{2019}t trusted: \(detail)
            Run `ssh \(host)` in Terminal to check and accept it.
            """, isTransient: false)
        guard let probe = try? await runCommand(Self.ssh, ["-v"] + sshOptions() + [host, "true"]),
              var problem = HostKeyProblem.parse(probe.stderr, address: host) else {
            return fallback
        }
        if let entry = problem.offending {
            problem.previousFingerprint = await fingerprint(of: entry)
        }
        for other in hosts where other != host {
            if await knownFingerprints(for: other).contains(problem.fingerprint) {
                problem.matchingAddresses.append(other)
            }
        }
        return ConnectionFailure(problem.summary, isTransient: false, hostKey: problem)
    }

    func trustHostKey(_ problem: HostKeyProblem) async throws {
        if problem.kind == .changed, let entry = problem.offending {
            try await removeEntry(entry, expecting: problem.previousFingerprint)
        }
        // accept-new adds an unknown key but never replaces a known one.
        let r = try await runCommand(Self.ssh, ["-v", "-o", "StrictHostKeyChecking=accept-new"]
                                     + sshOptions() + [problem.address, "true"])
        guard let seen = HostKeyProblem.parse(r.stderr, address: problem.address)?.fingerprint
                ?? Self.serverKey(in: r.stderr) else {
            throw ProcessFailure(message: "Couldn\u{2019}t reach \(problem.address) to check its key. Try again.")
        }
        if seen != problem.fingerprint {
            // The server answered with another key between showing it and
            // trusting it: take back whatever ssh just added.
            if let added = Self.addedName(in: r.stderr) {
                _ = try? await runCommand(Self.sshKeygen, ["-R", added])
            }
            throw ProcessFailure(message: """
                \(problem.address) presented a different key (\(seen)) from the one shown (\(problem.fingerprint)), so it wasn\u{2019}t trusted. \
                Check the server before connecting again.
                """)
        }
    }

    /// "debug1: Server host key: ssh-ed25519 SHA256:…" → the fingerprint.
    static func serverKey(in log: String) -> String? {
        for line in log.split(whereSeparator: \.isNewline) {
            if let r = line.range(of: "Server host key: ") {
                let parts = line[r.upperBound...].split(separator: " ")
                if parts.count >= 2 { return String(parts[1]) }
            }
        }
        return nil
    }

    /// "Warning: Permanently added 'host' (ED25519) to …" → "host".
    static func addedName(in log: String) -> String? {
        guard let r = log.range(of: "Permanently added '"),
              let end = log[r.upperBound...].firstIndex(of: "'") else { return nil }
        return String(log[r.upperBound..<end])
    }

    /// The fingerprints known_hosts trusts for an address, looked up the way
    /// ssh would: by its HostKeyAlias, or its resolved HostName and port.
    private func knownFingerprints(for address: String) async -> [String] {
        guard let g = try? await runCommand(Self.ssh, ["-G", address]), g.status == 0 else { return [] }
        var config: [String: String] = [:]
        for line in g.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { config[String(parts[0])] = String(parts[1]) }
        }
        let name: String
        if let alias = config["hostkeyalias"], alias != "none" {
            name = alias
        } else {
            let hostname = config["hostname"] ?? address
            let port = config["port"] ?? "22"
            name = port == "22" ? hostname : "[\(hostname)]:\(port)"
        }
        guard let r = try? await runCommand(Self.sshKeygen, ["-l", "-F", name]) else { return [] }
        return Self.fingerprints(in: r.stdout)
    }

    private func fingerprint(of entry: HostKeyProblem.Entry) async -> String? {
        guard let line = try? Self.knownHostsLines(entry.file)[safe: entry.line - 1],
              let r = try? await runCommand(Self.sshKeygen, ["-l", "-f", "-"], stdin: .text(line + "\n")) else { return nil }
        return Self.fingerprints(in: r.stdout).first
    }

    /// Removes one line from a known_hosts file, after checking it still holds
    /// the key the user saw. The previous file is kept as `<file>.old`, as
    /// `ssh-keygen -R` does.
    private func removeEntry(_ entry: HostKeyProblem.Entry, expecting expected: String?) async throws {
        var lines = try Self.knownHostsLines(entry.file)
        guard entry.line >= 1, entry.line <= lines.count else {
            throw ProcessFailure(message: "\(entry.file) changed since the key was checked. Try again.")
        }
        if let expected, await fingerprint(of: entry) != expected {
            throw ProcessFailure(message: "\(entry.file) changed since the key was checked. Try again.")
        }
        let url = URL(fileURLWithPath: entry.file)
        let original = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: entry.file)
        try original.write(to: URL(fileURLWithPath: entry.file + ".old"), options: .atomic)
        lines.remove(at: entry.line - 1)
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try Data(text.utf8).write(to: url, options: .atomic)
        if let mode = attributes[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: entry.file)
        }
    }

    private static func knownHostsLines(_ file: String) throws -> [String] {
        let text = try String(contentsOfFile: file, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Every "SHA256:…" in `ssh-keygen -l` output, skipping its comments.
    static func fingerprints(in output: String) -> [String] {
        output.split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .flatMap { $0.split(separator: " ") }
            .filter { $0.hasPrefix("SHA256:") }
            .map(String.init)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
