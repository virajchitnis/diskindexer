import CryptoKit
import DiskIndexerKit
@testable import DiskIndexerSSH
import Foundation
import Testing

@Test func parsesAddresses() {
    #expect(SSHAddress("me@host") == SSHAddress(user: "me", host: "host"))
    #expect(SSHAddress(" me@host:2222 ") == SSHAddress(user: "me", host: "host", port: 2222))
    #expect(SSHAddress("host") == nil)
    #expect(SSHAddress("@host") == nil)
    #expect(SSHAddress(user: "me", host: "h", port: 2222).description == "me@h:2222")
}

@Test func relayCommandQuotesItsArguments() throws {
    guard #available(macOS 15.0, *) else { return }
    // Run the command with a stand-in diskindexer that prints its arguments.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("di relay \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fake = dir.appendingPathComponent("it's diskindexer")
    try "#!/bin/sh\nprintf '%s|' \"$@\"\n".write(to: fake, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", SSHChannelTransport.relayCommand(binary: fake.path, socket: "/a b/it's.sock")]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    p.waitUntilExit()
    #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "connect|--socket|/a b/it's.sock|")
}

/// A real sshd (as this user, on a free port) in front of a real
/// `diskindexer serve`, reached through SSHChannelTransport and APIClient.
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["DISKINDEXER_BIN"] != nil
                && FileManager.default.fileExists(atPath: "/usr/sbin/sshd")))
struct SSHEndToEnd {
    @Test func connectsThroughSSH() async throws {
        guard #available(macOS 15.0, *) else { return }
        let env = try SSHTestServer()
        defer { env.stop() }

        let store = MemoryHostKeyStore()
        let transport = env.transport(store: store)

        // Unknown host key: reported, not accepted.
        do {
            _ = try await transport.connect()
            Issue.record("connected to an untrusted host")
        } catch let f as ConnectionFailure {
            let problem = try #require(f.hostKey)
            #expect(problem.kind == .unknown)
            #expect(problem.fingerprint == env.hostFingerprint)
            try await transport.trustHostKey(problem)
        }

        let endpoint = try await transport.connect()
        print("ssh timings:", transport.timings)
        let api = APIClient(endpoint: endpoint)
        let info = try await api.info()
        #expect(info.apiVersion == supportedAPIVersion)

        // More at once than OpenSSH allows sessions: URLSession queues them.
        let started = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { _ = try await api.disks() } }
            try await group.waitForAll()
        }
        print("30 concurrent requests:", Date().timeIntervalSince(started))

        // A progress stream stays open for the whole job.
        let tree = env.dir + "/disk"
        for i in 0..<200 {
            try FileManager.default.createDirectory(atPath: "\(tree)/C\(i % 4)", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: "\(tree)/C\(i % 4)/f\(i).txt", contents: Data("x".utf8))
        }
        let job = try await api.startIndex(IndexRequest(disk: "SSHDisk", mountPath: tree))
        var last: Job?
        for try await update in api.jobEvents(job.id) { last = update }
        #expect(last?.state == .done)
        let found = try await api.search(SearchRequest(query: "f199"))
        #expect(found.results.contains { $0.name == "f199.txt" })
        transport.disconnect()
    }

    @Test func startsAServerOnDemand() async throws {
        guard #available(macOS 15.0, *) else { return }
        let env = try SSHTestServer()
        defer { env.stop() }
        let store = MemoryHostKeyStore()
        store.trust(env.hostKeyLine, for: env.address.description)
        // No server on this socket, but diskindexer is on PATH: the
        // transport starts one for the connection.
        let socket = env.dir + "/ondemand.sock"
        let transport = SSHChannelTransport(name: "test", addresses: [env.address], key: env.clientKey,
                                            hostKeys: store, socketPath: socket, binary: env.binary,
                                            onDemandIdleExit: 1)
        let api = APIClient(endpoint: try await transport.connect())
        #expect(try await api.info().persistent == false)

        // sshd keeps it running after the connection closes, until it has
        // been idle for onDemandIdleExit.
        transport.disconnect()
        for _ in 0..<100 where FileManager.default.fileExists(atPath: socket) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(!FileManager.default.fileExists(atPath: socket))

        // A socket left by a server that was killed: the next connect starts
        // a server in its place.
        let dead = try #require(socket.withCString { p -> Int32? in
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { _ = strlcpy($0.baseAddress!.assumingMemoryBound(to: CChar.self), p, $0.count) }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            return ok == 0 ? fd : nil
        })
        close(dead)
        #expect(FileManager.default.fileExists(atPath: socket))
        let again = APIClient(endpoint: try await transport.connect())
        #expect(try await again.info().persistent == false)
        transport.disconnect()
    }

    @Test func rejectsAnUnknownKey() async throws {
        guard #available(macOS 15.0, *) else { return }
        let env = try SSHTestServer()
        defer { env.stop() }
        let store = MemoryHostKeyStore()
        store.trust(env.hostKeyLine, for: env.address.description)
        let transport = SSHChannelTransport(name: "test", addresses: [env.address],
                                            key: Curve25519.Signing.PrivateKey(), hostKeys: store,
                                            socketPath: env.socket, binary: env.binary)
        do {
            _ = try await transport.connect()
            Issue.record("logged in with a key the server doesn't know")
        } catch let f as ConnectionFailure {
            #expect(!f.isTransient)
        }
    }
}

/// Scratch sshd + serve. Paths live under /tmp: Unix socket paths are short.
@available(macOS 15.0, *)
final class SSHTestServer {
    let dir: String
    let port = Int.random(in: 20000...40000)
    let clientKey = Curve25519.Signing.PrivateKey()
    let socket: String
    private var sshd: Process?
    private var serve: Process?
    private var serveStdin = Pipe()
    var hostKeyLine = ""
    var hostFingerprint = ""

    var address: SSHAddress { SSHAddress(user: NSUserName(), host: "127.0.0.1", port: port) }
    /// The build under test. Also on the sessions' PATH, so the server
    /// lookup finds a diskindexer to start on demand.
    let binary = ProcessInfo.processInfo.environment["DISKINDEXER_BIN"]!

    init() throws {
        var template = Array("/tmp/di-ssh.XXXXXX".utf8CString)
        guard let p = mkdtemp(&template) else { throw CocoaError(.fileWriteUnknown) }
        dir = String(cString: p)
        socket = dir + "/s.sock"

        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", dir + "/host_key"])
        hostKeyLine = try String(contentsOfFile: dir + "/host_key.pub", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fp = try run("/usr/bin/ssh-keygen", ["-l", "-f", dir + "/host_key.pub"])
        hostFingerprint = String(fp.split(separator: " ")[1])
        try (SSHKeys.openSSHPublicKey(clientKey, comment: "test") + "\n")
            .write(toFile: dir + "/authorized_keys", atomically: true, encoding: .utf8)
        try """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(dir)/host_key
            AuthorizedKeysFile \(dir)/authorized_keys
            PidFile \(dir)/sshd.pid
            UsePAM no
            StrictModes no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            SetEnv "PATH=\((binary as NSString).deletingLastPathComponent):/usr/bin:/bin"
            """.write(toFile: dir + "/sshd_config", atomically: true, encoding: .utf8)

        let s = Process()
        s.executableURL = URL(fileURLWithPath: binary)
        s.arguments = ["serve", "--listen", "unix:" + socket, "--db", dir + "/x.diskindex", "--stdin-watch"]
        s.standardInput = serveStdin
        s.standardOutput = FileHandle.nullDevice
        s.standardError = FileHandle.nullDevice
        try s.run()
        serve = s

        let d = Process()
        d.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        d.arguments = ["-D", "-e", "-f", dir + "/sshd_config"]
        FileManager.default.createFile(atPath: dir + "/sshd.log", contents: nil)
        d.standardError = FileHandle(forWritingAtPath: dir + "/sshd.log")
        try d.run()
        sshd = d

        // Wait for both to listen. (Probing sshd's port would count as
        // connections that never authenticate.)
        for _ in 0..<100 {
            let log = (try? String(contentsOfFile: dir + "/sshd.log", encoding: .utf8)) ?? ""
            if FileManager.default.fileExists(atPath: socket) && log.contains("Server listening") { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    var sshdLog: String { (try? String(contentsOfFile: dir + "/sshd.log", encoding: .utf8)) ?? "" }

    func transport(store: HostKeyStore, socket: String? = nil) -> SSHChannelTransport {
        SSHChannelTransport(name: "test", addresses: [address], key: clientKey, hostKeys: store,
                            socketPath: socket ?? self.socket, binary: binary)
    }

    func stop() {
        sshd?.terminate()
        try? serveStdin.fileHandleForWriting.close()
        serve?.terminate()
        try? FileManager.default.removeItem(atPath: dir)
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return text
    }
}

/// How long a full page of results takes through the bridge. Run with
/// DISKINDEXER_SSH_PERF=1; prints timings rather than asserting them.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DISKINDEXER_SSH_PERF"] != nil))
struct SSHThroughput {
    @Test func largeResponses() async throws {
        guard #available(macOS 15.0, *) else { return }
        let env = try SSHTestServer()
        defer { env.stop() }
        let store = MemoryHostKeyStore()
        store.trust(env.hostKeyLine, for: env.address.description)
        let transport = env.transport(store: store)
        let api = APIClient(endpoint: try await transport.connect())

        let tree = env.dir + "/big"
        for i in 0..<3000 {
            let dir = "\(tree)/C\(i % 5)/folder-\(i / 100)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // Random names, so gzip can't shrink the response much.
            let name = (0..<6).map { _ in UUID().uuidString }.joined().prefix(200)
            FileManager.default.createFile(atPath: "\(dir)/\(name)-\(i).mkv", contents: nil)
        }
        let job = try await api.startIndex(IndexRequest(disk: "Big", mountPath: tree))
        for try await _ in api.jobEvents(job.id) {}

        // The same server over plain TCP, for comparison.
        let direct = Process()
        direct.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DISKINDEXER_BIN"]!)
        direct.arguments = ["serve", "--listen", "127.0.0.1:0", "--token", "t", "--db", env.dir + "/x.diskindex", "--stdin-watch"]
        let directOut = Pipe(), directIn = Pipe()
        direct.standardOutput = directOut
        direct.standardInput = directIn
        try direct.run()
        defer { try? directIn.fileHandleForWriting.close() }
        let line = String(decoding: directOut.fileHandleForReading.availableData, as: UTF8.self)
        let port = line.split(separator: ":").last!.filter(\.isNumber)
        let tcp = APIClient(endpoint: Endpoint(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: "t"))

        for round in 0..<3 {
            var t = Date()
            let r = try await api.search(SearchRequest(query: ""))
            let search = Date().timeIntervalSince(t)
            t = Date()
            _ = try await api.collections()
            print("round \(round): search \(r.results.count) results \(search)s, collections \(Date().timeIntervalSince(t))s")
            t = Date()
            _ = try await tcp.search(SearchRequest(query: ""))
            print("  APIClient over plain TCP:", Date().timeIntervalSince(t))
            let curl = Process()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = ["-s", "-o", "/dev/null", "-w", "%{time_total} %{size_download}", "--compressed",
                              "--unix-socket", env.socket, "-H", "Content-Type: application/json",
                              "-d", #"{"query":""}"#, "http://x/v1/search"]
            let out = Pipe()
            curl.standardOutput = out
            try curl.run()
            curl.waitUntilExit()
            print("  direct (curl, s bytes):", String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        transport.disconnect()
    }
}
