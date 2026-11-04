import Citadel
import CryptoKit
import DiskIndexerKit
import Foundation
import Network
import NIOCore
import NIOSSH
import os

/// Reaches a diskindexer server over SSH without an ssh binary, for iOS.
///
/// One SSH connection per connect(). A loopback listener hands each HTTP
/// connection URLSession opens to its own exec channel running
/// `diskindexer connect`, which relays it to the server's Unix socket
/// (swift-nio-ssh can't forward Unix sockets). APIClient sees an ordinary
/// http://127.0.0.1 endpoint.
@available(macOS 15.0, *)
public final class SSHChannelTransport: Transport, HostKeyTrusting, @unchecked Sendable {
    public let displayName: String
    public var isLocal: Bool { false }
    public var onDisconnect: (@Sendable (String) -> Void)?
    public var activeAddress: String? { addresses.count > 1 ? active?.description : nil }

    let addresses: [SSHAddress]
    let key: Curve25519.Signing.PrivateKey
    let hostKeys: HostKeyStore
    /// Shell command that relays stdin/stdout to the server; see relayCommand.
    let command: String

    /// Seconds spent in each step of the last connect(), for the spike.
    public private(set) var timings: [String: TimeInterval] = [:]

    private let lock = NSLock()
    private var client: SSHClient?
    private var listener: NWListener?
    private var active: SSHAddress?
    private var stopping = false
    private let queue = DispatchQueue(label: "diskindexer.ssh.bridge")

    public init(name: String, addresses: [SSHAddress], key: Curve25519.Signing.PrivateKey,
                hostKeys: HostKeyStore, socketPath: String? = nil, command: String? = nil) {
        displayName = name
        self.addresses = addresses
        self.key = key
        self.hostKeys = hostKeys
        self.command = command ?? Self.relayCommand(socketPath: socketPath)
    }

    /// Runs `diskindexer connect` from ~/.local/bin or PATH, through sh so it
    /// works whatever the login shell. Exit 4: not installed; 3: not running.
    /// Citadel doesn't always report the exit status, so probe() also reads
    /// what they print.
    public static func relayCommand(socketPath: String?) -> String {
        let socket = socketPath.flatMap { $0.isEmpty ? nil : " --socket " + shellQuote($0) } ?? ""
        let script = """
            b="$HOME/.local/bin/diskindexer"; [ -x "$b" ] || b=$(command -v diskindexer) || \
            { echo "diskindexer: not installed" >&2; exit 4; }; \
            exec "$b" connect\(socket)
            """
        return "sh -c " + shellQuote(script)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    public func connect() async throws -> Endpoint {
        lock.withLock { stopping = false }
        var started = Date()
        let (address, client) = try await firstReachable(addresses.map(\.description)) { text, isLast in
            let address = addresses.first { $0.description == text }!
            return try await login(address, timeout: isLast ? 10 : 4)
        }
        timings["login"] = Date().timeIntervalSince(started)
        let chosen = addresses.first { $0.description == address }
        lock.withLock {
            self.client = client
            active = chosen
        }
        client.onDisconnect { [weak self] in
            guard let self, !self.lock.withLock({ self.stopping }) else { return }
            self.onDisconnect?("The SSH connection to \(self.displayName) closed.")
        }

        started = Date()
        do {
            try await probe(client)
        } catch {
            disconnect()
            throw error
        }
        timings["probe"] = Date().timeIntervalSince(started)

        started = Date()
        let port = try await startListener()
        timings["listen"] = Date().timeIntervalSince(started)
        return Endpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
    }

    public func disconnect() {
        let (client, listener) = lock.withLock {
            stopping = true
            defer { self.client = nil; self.listener = nil }
            return (self.client, self.listener)
        }
        listener?.cancel()
        if let client { Task { try? await client.close() } }
    }

    // MARK: Login

    private func login(_ address: SSHAddress, timeout: Int64) async throws -> SSHClient {
        let validator = HostKeyCheck(address: address.description, store: hostKeys)
        do {
            return try await SSHClient.connect(
                host: address.host, port: address.port,
                authenticationMethod: .ed25519(username: address.user, privateKey: key),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                connectTimeout: .seconds(timeout))
        } catch {
            if let problem = validator.problem {
                throw ConnectionFailure(problem.kind == .unknown
                    ? "\(address.host) isn\u{2019}t a trusted server yet."
                    : "The host key of \(address.host) has changed.",
                    isTransient: false, hostKey: problem)
            }
            throw Self.failure(error, address: address)
        }
    }

    /// Sorts Citadel/NIO errors the way SSHFailureKind sorts ssh's stderr.
    static func failure(_ error: Error, address: SSHAddress) -> ConnectionFailure {
        if error is AuthenticationFailed || "\(error)".contains("allAuthenticationOptionsFailed") {
            return ConnectionFailure("""
                \(address.host) didn\u{2019}t accept this device\u{2019}s key for \(address.user). \
                Add its public key to ~/.ssh/authorized_keys there.
                """, isTransient: false)
        }
        // NIOConnectionError lives in NIOPosix, which only Citadel imports.
        if error is IOError || error is ChannelError || "\(type(of: error))" == "NIOConnectionError"
            || "\(error)".localizedCaseInsensitiveContains("timeout") {
            return ConnectionFailure("Can\u{2019}t reach \(address.host): \(error)", isTransient: true, reason: .unreachable)
        }
        return ConnectionFailure("SSH to \(address.host) failed: \(error)", isTransient: true)
    }

    // MARK: Relay

    /// One request through a relay, so a missing server is reported here
    /// with a clear message rather than as a failed HTTP request.
    private func probe(_ client: SSHClient) async throws {
        let request = "GET /v1/info HTTP/1.1\r\nHost: diskindexer\r\nConnection: close\r\n\r\n"
        var reply = ""
        var errors = ""
        do {
            try await client.withExec(command) { inbound, outbound in
                try await outbound.write(ByteBuffer(string: request))
                for try await out in inbound {
                    switch out {
                    case .stdout(let b): reply += String(buffer: b)
                    case .stderr(let b): errors += String(buffer: b)
                    }
                }
            }
        } catch ChannelError.alreadyClosed {
            // withExec closes the channel itself once perform returns, and
            // fails if the command already ended it, as it does here.
        } catch let e as SSHClient.CommandFailed where e.exitCode == 3 || e.exitCode == 4 {
            throw ConnectionFailure(e.exitCode == 4
                ? "diskindexer isn\u{2019}t installed on \(displayName)."
                : "diskindexer isn\u{2019}t running on \(displayName).",
                isTransient: true, reason: .notRunning)
        } catch let e as SSHClient.CommandFailed {
            throw ConnectionFailure("diskindexer connect failed on \(displayName) (exit \(e.exitCode)): \(errors)", isTransient: true)
        }
        if reply.isEmpty, errors.contains("diskindexer: not installed") || errors.contains("no server is running") {
            throw ConnectionFailure(errors.contains("not installed")
                ? "diskindexer isn\u{2019}t installed on \(displayName)."
                : "diskindexer isn\u{2019}t running on \(displayName).",
                isTransient: true, reason: .notRunning)
        }
        guard reply.hasPrefix("HTTP/1.1 200") else {
            throw ConnectionFailure("Unexpected reply from \(displayName): \(reply.prefix(200))\(errors)", isTransient: true)
        }
    }

    private func startListener() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.bridge(conn) }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let first = { resumed.withLock { was in defer { was = true }; return !was } }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if first() { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let e):
                    if first() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { self.listener = listener }
        return port
    }

    /// Relays one local connection through its own exec channel until either
    /// side closes.
    private func bridge(_ conn: NWConnection) {
        let opened = Date()
        let id = UInt16.random(in: 0...9999)
        trace.debug("bridge \(id) accept")
        conn.start(queue: queue)
        guard let client = lock.withLock({ self.client }) else { return conn.cancel() }
        let command = self.command
        Task {
            try? await client.withExec(command) { inbound, outbound in
                trace.debug("bridge \(id) exec ready at \(Date().timeIntervalSince(opened), format: .fixed(precision: 3))")
                await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        while let data = try await conn.receiveChunk() {
                            trace.debug("bridge \(id) up \(data.count) at \(Date().timeIntervalSince(opened), format: .fixed(precision: 3))")
                            try await outbound.write(ByteBuffer(bytes: data))
                        }
                    }
                    group.addTask {
                        for try await out in inbound {
                            if case .stdout(let b) = out { trace.debug("bridge \(id) down \(b.readableBytes) at \(Date().timeIntervalSince(opened), format: .fixed(precision: 3))") }
                            if case .stdout(let b) = out { try await conn.sendChunk(Data(buffer: b)) }
                        }
                    }
                    // Whichever side ends first ends the relay.
                    _ = try? await group.next()
                    conn.cancel()
                    group.cancelAll()
                }
            }
            conn.cancel()
        }
    }

    // MARK: Host keys

    public func trustHostKey(_ problem: HostKeyProblem) async throws {
        guard let presented = HostKeyCheck.presented[problem.address],
              HostKeyCheck.fingerprint(presented) == problem.fingerprint else {
            throw ConnectionFailure("The server\u{2019}s key changed again; connect once more to see it.", isTransient: false)
        }
        hostKeys.trust(String(openSSHPublicKey: presented), for: problem.address)
    }
}

/// user@host[:port], as entered in the server editor.
public struct SSHAddress: Sendable, Hashable, CustomStringConvertible {
    public var user: String
    public var host: String
    public var port: Int

    public init(user: String, host: String, port: Int = 22) {
        self.user = user
        self.host = host
        self.port = port
    }

    /// Parses "user@host" or "user@host:port". The user is required: there's
    /// no ~/.ssh/config to supply one.
    public init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let at = t.lastIndex(of: "@") else { return nil }
        user = String(t[..<at])
        var rest = String(t[t.index(after: at)...])
        port = 22
        if let colon = rest.lastIndex(of: ":"), let p = Int(rest[rest.index(after: colon)...]) {
            port = p
            rest = String(rest[..<colon])
        }
        host = rest
        guard !user.isEmpty, !host.isEmpty else { return nil }
    }

    public var description: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }
}

/// Trusted host keys by address, as OpenSSH public key lines.
public protocol HostKeyStore: AnyObject, Sendable {
    func trusted(for address: String) -> String?
    func trust(_ key: String, for address: String)
}

/// Accepts only the key trusted for this address, recording the one the
/// server presented so the UI can show it.
final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let address: String
    let store: HostKeyStore
    private(set) var problem: HostKeyProblem?

    /// The last key each address presented, for trustHostKey.
    nonisolated(unsafe) static var presented: [String: NIOSSHPublicKey] = [:]

    init(address: String, store: HostKeyStore) {
        self.address = address
        self.store = store
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        Self.presented[address] = hostKey
        let line = String(openSSHPublicKey: hostKey)
        let trusted = store.trusted(for: address)
        if let trusted, Self.sameKey(trusted, line) {
            return validationCompletePromise.succeed(())
        }
        problem = HostKeyProblem(
            address: address, kind: trusted == nil ? .unknown : .changed,
            keyType: HostKeyProblem.keyTypeName(String(line.prefix { $0 != " " })),
            fingerprint: Self.fingerprint(hostKey),
            previousFingerprint: trusted.flatMap { try? NIOSSHPublicKey(openSSHPublicKey: $0) }.map(Self.fingerprint))
        validationCompletePromise.fail(InvalidHostKey())
    }

    static func sameKey(_ a: String, _ b: String) -> Bool {
        a.split(separator: " ").prefix(2) == b.split(separator: " ").prefix(2)
    }

    /// "SHA256:…" as ssh prints it.
    static func fingerprint(_ key: NIOSSHPublicKey) -> String {
        let parts = String(openSSHPublicKey: key).split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "?" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

struct InvalidHostKey: Error {}

/// Timing of each bridged connection, at debug level: `log stream --level debug`.
let trace = Logger(subsystem: "com.virajchitnis.diskindexer", category: "bridge")

extension NWConnection {
    /// The next bytes received, or nil at end of stream.
    func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty { cont.resume(returning: data) }
                else if let error { cont.resume(throwing: error) }
                else if isComplete { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    func sendChunk(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }
}
