import Foundation
import Network
import Testing
@testable import DiskIndexerKit

// End-to-end tests of AppModel against a real `diskindexer serve` process,
// so they exercise the same Go code the app uses. The binary comes from
// $DISKINDEXER_BIN (set by `make test-apple`) or the repo root.

/// Launches `diskindexer serve` on a random port with its own scratch index.
/// crash() kills the server without going through disconnect(), which is what
/// a dropped tunnel or a dying child looks like to AppModel.
final class ServeTransport: Transport {
    let displayName = "Test server"
    let isLocal = true
    var onDisconnect: (@Sendable (String) -> Void)?

    let dbPath: String
    /// Fixed port and token, so a relaunch looks like the same server
    /// restarting behind a tunnel that stayed up. nil means random.
    let port: Int?
    let fixedToken: String?
    /// Exit with stdin like the app's own servers; false runs it like a
    /// service, which runs schedules.
    var stdinWatch = true
    private(set) var endpoint: Endpoint?
    private(set) var launches = 0
    private var process: Process?
    private var stopping = false

    init(dbPath: String, port: Int? = nil, token: String? = nil) {
        self.dbPath = dbPath
        self.port = port
        self.fixedToken = token
    }

    static func binaryPath() throws -> String {
        if let p = ProcessInfo.processInfo.environment["DISKINDEXER_BIN"], !p.isEmpty {
            return p
        }
        // apple/Tests/DiskIndexerKitTests/<file> → repo root
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let p = root.appendingPathComponent("diskindexer").path
        guard FileManager.default.isExecutableFile(atPath: p) else {
            throw APIError(status: 0, message: "diskindexer binary not found; run `make build` or set DISKINDEXER_BIN")
        }
        return p
    }

    func connect() async throws -> Endpoint {
        stopping = false
        let token = fixedToken ?? UUID().uuidString
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try Self.binaryPath())
        p.arguments = ["serve", "--listen", "127.0.0.1:\(port ?? 0)", "--db", dbPath] + (stdinWatch ? ["--stdin-watch"] : [])
        var env = ProcessInfo.processInfo.environment
        env["DISKINDEXER_TOKEN"] = token
        p.environment = env
        let stdout = Pipe()
        p.standardInput = Pipe()
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            guard let self, !self.stopping else { return }
            self.onDisconnect?("server exited")
        }
        try p.run()
        process = p
        launches += 1
        for try await line in stdout.fileHandleForReading.bytes.lines {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
               let addr = obj["listen"] {
                let ep = Endpoint(baseURL: URL(string: "http://\(addr)/")!, token: token)
                endpoint = ep
                return ep
            }
        }
        throw APIError(status: 0, message: "server exited before listening")
    }

    func disconnect() {
        stopping = true
        process?.terminate()
        process?.waitUntilExit()
        process = nil
    }

    func crash() {
        process?.terminate()
        process?.waitUntilExit()
    }
}

/// Fails the first `failures` connects with the given error, then connects
/// through `inner`.
final class FlakyTransport: Transport {
    let displayName = "Flaky"
    let isLocal = true
    var onDisconnect: (@Sendable (String) -> Void)? {
        get { inner.onDisconnect }
        set { inner.onDisconnect = newValue }
    }
    let inner: ServeTransport
    var failures: Int
    let error: Error
    private(set) var attempts = 0

    init(_ inner: ServeTransport, failures: Int, error: Error) {
        self.inner = inner
        self.failures = failures
        self.error = error
    }

    func connect() async throws -> Endpoint {
        attempts += 1
        if failures > 0 {
            failures -= 1
            throw error
        }
        return try await inner.connect()
    }

    func disconnect() { inner.disconnect() }
}

/// A server that "isn't running" until installed: connect fails like the SSH
/// transport does (reason .notRunning) and installServer starts it.
final class InstallableTransport: Transport, ServerManaging {
    let displayName = "Fresh server"
    let isLocal = false
    var onDisconnect: (@Sendable (String) -> Void)? {
        get { inner.onDisconnect }
        set { inner.onDisconnect = newValue }
    }
    let inner: ServeTransport
    private(set) var installed = false
    let bundledVersion: String? = "1.3.1"

    init(_ inner: ServeTransport) { self.inner = inner }

    func connect() async throws -> Endpoint {
        guard installed else {
            throw ConnectionFailure("diskindexer isn't running on Fresh server", isTransient: true, reason: .notRunning)
        }
        return try await inner.connect()
    }

    func disconnect() { inner.disconnect() }

    func installServer(progress: @escaping @Sendable (String) -> Void) async throws -> InstallReport {
        progress("Copying diskindexer\u{2026}")
        progress("Starting the service\u{2026}")
        installed = true
        return InstallReport(version: "v1.3.1", lingerEnabled: false, lingerCommand: "sudo loginctl enable-linger me")
    }
}

/// A server whose host key isn't trusted until trustHostKey runs; with
/// `rejectTrust`, trusting fails as if the server's key changed meanwhile.
final class UntrustedTransport: Transport, HostKeyTrusting {
    let displayName = "New server"
    let isLocal = false
    var onDisconnect: (@Sendable (String) -> Void)? {
        get { inner.onDisconnect }
        set { inner.onDisconnect = newValue }
    }
    let inner: ServeTransport
    let problem = HostKeyProblem(address: "new.local", kind: .unknown, keyType: "ED25519", fingerprint: "SHA256:abc")
    var rejectTrust = false
    private(set) var trusted: [HostKeyProblem] = []
    private(set) var attempts = 0

    init(_ inner: ServeTransport) { self.inner = inner }

    func connect() async throws -> Endpoint {
        attempts += 1
        guard !trusted.isEmpty else {
            throw ConnectionFailure(problem.summary, isTransient: false, hostKey: problem)
        }
        return try await inner.connect()
    }

    func disconnect() { inner.disconnect() }

    func trustHostKey(_ problem: HostKeyProblem) async throws {
        if rejectTrust { throw APIError(status: 0, message: "new.local presented a different key") }
        trusted.append(problem)
    }
}

/// A free loopback port for tests that need a stable address.
private func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
        }
    }
    guard ok else { throw APIError(status: 0, message: "no free port") }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// Connects to an already-running server, like a second app window or a
/// second Mac pointed at the same remote.
final class FixedTransport: Transport {
    let displayName = "Fixed"
    let isLocal = false
    var onDisconnect: (@Sendable (String) -> Void)?
    let endpoint: Endpoint

    init(_ endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    func connect() async throws -> Endpoint { endpoint }
    func disconnect() {}
}

/// A slow link: forwards TCP to a server, holding every chunk the client
/// sends for `delay` first. Answers come straight back, so each request
/// costs about `delay`, like a round trip on a slow network.
final class DelayProxy: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DelayProxy")
    private(set) var port: UInt16 = 0

    init(to target: UInt16, delay: TimeInterval) async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let queue = self.queue
        listener.newConnectionHandler = { client in
            let server = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!, using: .tcp)
            Self.pipe(from: client, to: server, delay: delay, queue: queue)
            Self.pipe(from: server, to: client, delay: 0, queue: queue)
            client.start(queue: queue)
            server.start(queue: queue)
        }
        let ready = AsyncStream<UInt16> { cont in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state { cont.yield(listener.port?.rawValue ?? 0); cont.finish() }
            }
        }
        listener.start(queue: queue)
        for await p in ready { port = p }
    }

    private static func pipe(from: NWConnection, to: NWConnection, delay: TimeInterval, queue: DispatchQueue) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            // Same delay on one serial queue, so chunks stay in order.
            queue.asyncAfter(deadline: .now() + delay) {
                if let data, !data.isEmpty { to.send(content: data, completion: .idempotent) }
                if done || error != nil {
                    to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                }
            }
            if !done && error == nil { pipe(from: from, to: to, delay: delay, queue: queue) }
        }
    }

    func stop() { listener.cancel() }
}

/// A ServeTransport reached through a DelayProxy.
final class SlowTransport: Transport {
    let displayName = "Slow server"
    let isLocal = false
    var onDisconnect: (@Sendable (String) -> Void)? {
        get { inner.onDisconnect }
        set { inner.onDisconnect = newValue }
    }
    let inner: ServeTransport
    let delay: TimeInterval
    private var proxy: DelayProxy?

    init(_ inner: ServeTransport, delay: TimeInterval) {
        self.inner = inner
        self.delay = delay
    }

    func connect() async throws -> Endpoint {
        let ep = try await inner.connect()
        let proxy = try await DelayProxy(to: UInt16(ep.baseURL.port!), delay: delay)
        self.proxy = proxy
        return Endpoint(baseURL: URL(string: "http://127.0.0.1:\(proxy.port)/")!, token: ep.token)
    }

    func disconnect() {
        proxy?.stop()
        inner.disconnect()
    }
}

private func makeDisk(_ files: [String: String]) throws -> String {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("di-disk-\(UUID().uuidString)")
    for (rel, content) in files {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    return root.path
}

private func scratchDB() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("di-test-\(UUID().uuidString).diskindex").path
}

/// Polls until cond holds or the timeout passes; returns the final result.
@MainActor
private func eventually(timeout: TimeInterval = 15, _ cond: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return cond()
}

/// Four files in three collections; both a.mkv copies are the same size, so
/// they count as duplicates.
private let sampleDisk = [
    "Movies/a.mkv": "aaa",
    "Movies/b.mkv": "bb",
    "Backup/a.mkv": "aaa",
    "Music/x.flac": "x",
]

/// Connects a fresh model to a fresh server and indexes sampleDisk as "Disk1".
@MainActor
private func connectedModel(stdinWatch: Bool = true) async throws -> (AppModel, ServeTransport) {
    let model = AppModel()
    let transport = ServeTransport(dbPath: scratchDB())
    transport.stdinWatch = stdinWatch
    model.connect(transport)
    #expect(await eventually { model.status == .connected }, "status: \(model.status)")
    try await model.startIndex(IndexRequest(disk: "Disk1", mountPath: try makeDisk(sampleDisk)))
    #expect(await eventually { model.jobs.first?.state == .done })
    // Finishing a job refreshes the sidebar and the results on its own.
    #expect(await eventually { model.diskNodes.first?.collections.count == 3 && model.results.count == 7 })
    return (model, transport)
}

@MainActor
@Suite(.serialized)
struct AppModelIntegrationTests {
    @Test func indexThenSearchAndFilter() async throws {
        let (model, transport) = try await connectedModel()
        defer { model.disconnect() }
        #expect(transport.launches == 1)
        #expect(model.diskNodes.map(\.label) == ["Disk1"])
        #expect(model.diskNodes[0].collections.map(\.label) == ["Backup", "Movies", "Music"])

        // Duplicates: the two a.mkv copies, but not b.mkv.
        let dupes = model.results.filter(model.isDuplicate).map(\.path).sorted()
        #expect(dupes == ["Disk1/Backup/a.mkv", "Disk1/Movies/a.mkv"])

        model.typeFilter = .files
        #expect(await eventually { model.results.count == 4 && model.results.allSatisfy { !$0.isDir } })

        model.sidebarSelection = .collection(disk: "Disk1", collection: "Movies")
        #expect(await eventually { model.results.map(\.name) == ["a.mkv", "b.mkv"] })
        // With only one a.mkv in view there is nothing to highlight.
        #expect(model.duplicateKeys.isEmpty)

        model.sidebarSelection = .allDisks
        model.query = "flac"
        #expect(await eventually { model.results.map(\.name) == ["x.flac"] })
        #expect(!model.capped)
    }

    @Test func rapidTypingSettlesOnLastQuery() async throws {
        let (model, _) = try await connectedModel()
        defer { model.disconnect() }
        for q in ["a", "a.", "a.m", "b", "b.mkv", "fl", "flac"] {
            model.query = q
        }
        #expect(await eventually { model.results.map(\.name) == ["x.flac"] })
        // A stale response for an earlier query must not overwrite it later.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(model.results.map(\.name) == ["x.flac"])
        #expect(model.searchError == nil)
    }

    /// The results table is rebuilt (see resultsGeneration) only when the
    /// result set changes, so a refresh with the same results keeps the
    /// table and its scroll position.
    @Test func resultsGenerationOnlyChangesWithResults() async throws {
        let (model, _) = try await connectedModel()
        defer { model.disconnect() }
        let gen = model.resultsGeneration

        model.scheduleSearch(debounce: false)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(model.resultsGeneration == gen, "same results, same table")

        model.query = "flac"
        #expect(await eventually { model.results.map(\.name) == ["x.flac"] })
        #expect(model.resultsGeneration == gen + 1)

        // Re-sorting reorders rows in place; it isn't a new result set.
        model.sortOrder = [KeyPathComparator(\FileItem.size)]
        #expect(model.resultsGeneration == gen + 1)
    }

    @Test func sortOrderAppliesToResults() async throws {
        let (model, _) = try await connectedModel()
        defer { model.disconnect() }
        model.typeFilter = .files
        #expect(await eventually { model.results.count == 4 })
        model.sortOrder = [KeyPathComparator(\FileItem.size, order: .reverse)]
        #expect(model.results.map(\.size) == [3, 3, 2, 1])
    }

    @Test func renameAndDeleteCollections() async throws {
        let (model, _) = try await connectedModel()
        defer { model.disconnect() }
        let coll = { (label: String) in model.diskNodes[0].collections.first { $0.label == label } }

        model.sidebarSelection = .collection(disk: "Disk1", collection: "Movies")
        await model.renameCollection(try #require(coll("Movies")), to: "Films")
        #expect(model.actionError == nil)
        #expect(model.diskNodes[0].collections.map(\.label) == ["Backup", "Films", "Music"])
        // The active filter follows the rename instead of going blank.
        #expect(model.sidebarSelection == .collection(disk: "Disk1", collection: "Films"))
        #expect(await eventually { model.results.contains { $0.name == "b.mkv" } })

        model.sidebarSelection = .allDisks
        await model.deleteCollection(try #require(coll("Backup")))
        #expect(model.diskNodes[0].collections.map(\.label) == ["Films", "Music"])
        #expect(await eventually { model.results.count == 5 && !model.results.contains { $0.path.hasPrefix("Disk1/Backup") } })

        await model.deleteDisk(model.diskNodes[0])
        #expect(model.diskNodes.isEmpty)
        #expect(await eventually { model.results.isEmpty })
    }

    @Test func addCollectionToExistingDiskWithoutMountPath() async throws {
        let (model, _) = try await connectedModel()
        defer { model.disconnect() }

        // A copy of a collection that lives elsewhere on the server, with a
        // stray file next to it that must not end up on the disk.
        let copyRoot = try makeDisk(["Photos/beach.jpg": "sand", "stray.txt": "x"])
        var draft = IndexDraft(addingTo: model.diskNodes[0])
        draft.collections[0].label = "Photos"
        draft.collections[0].path = (copyRoot as NSString).appendingPathComponent("Photos")
        #expect(draft.isValid)
        try await model.startIndex(draft.request)

        #expect(await eventually { model.jobs.first?.state == .done })
        #expect(model.jobs.first?.stats?.deleted == 0)
        #expect(await eventually { model.diskNodes[0].collections.map(\.label) == ["Backup", "Movies", "Music", "Photos"] })
        #expect(await eventually { model.results.contains { $0.path == "Disk1/Photos/beach.jpg" } })
        #expect(!model.results.contains { $0.name == "stray.txt" })
        // Everything indexed before is still there.
        #expect(model.results.count == 9)
    }

    @Test func reindexCollectionFromCopyKeepsItsLocation() async throws {
        let (model, _) = try await connectedModel()
        defer { model.disconnect() }
        #expect(!model.schedulesAvailable, "a server that exits with the app runs no schedules")
        let node = model.diskNodes[0]
        let movies = try #require(node.collections.first { $0.label == "Movies" })

        let copy = try makeDisk(["a.mkv": "aaa", "c.mkv": "cc"])
        var draft = IndexDraft(reindexing: movies, in: node)
        #expect(draft.collections[0].path == movies.rootPath && !draft.readsElsewhere)
        draft.collections[0].path = copy
        #expect(draft.readsElsewhere && draft.isValid)
        #expect(draft.request.mountPath == "" && draft.request.collections?.first?.keepRootPath == true)
        try await model.startIndex(draft.request)
        #expect(await eventually { model.jobs.first?.state == .done })
        #expect(model.jobs.first?.stats?.added == 1 && model.jobs.first?.stats?.deleted == 1)
        #expect(await eventually { model.results.contains { $0.path == "Disk1/Movies/c.mkv" } })
        #expect(model.diskNodes[0].collections.first { $0.label == "Movies" }?.rootPath == movies.rootPath)

        // Remembered: the copy becomes its location.
        draft.rememberLocation = true
        #expect(draft.request.collections?.first?.keepRootPath == nil)
        try await model.startIndex(draft.request)
        #expect(await eventually { model.jobs.first?.state == .done })
        #expect(await eventually { model.diskNodes[0].collections.first { $0.label == "Movies" }?.rootPath == copy })
    }

    @Test func schedulesRunSkipAndFollowTheirCollection() async throws {
        let (model, _) = try await connectedModel(stdinWatch: false)
        defer { model.disconnect() }
        #expect(model.schedulesAvailable)
        #expect(model.schedules.isEmpty)
        let node = model.diskNodes[0]
        let music = try #require(node.collections.first { $0.label == "Music" })

        // A collection read from a copy, every 6 hours.
        let copy = try makeDisk(["x.flac": "x", "y.flac": "y"])
        var draft = ScheduleDraft(node: node, collection: music)
        draft.path = copy
        draft.unit = .hours
        draft.every = 6
        try await model.saveSchedule(draft.request)
        let s = try #require(model.schedule(disk: "Disk1", collection: "Music"))
        #expect(s.path == copy && s.intervalHours == 6 && s.nextRunAt != nil)
        #expect(model.schedule(disk: "Disk1") == nil)

        await model.runSchedule(s)
        let job = try #require(model.jobs.first)
        #expect(job.schedule == s.scheduleID)
        #expect(await eventually { model.jobs.first?.state == .done })
        #expect(await eventually { model.schedules.first?.lastStatus == "done" })
        #expect(model.schedules.first?.lastMessage == "1 added, 0 updated, 0 removed")
        #expect(await eventually { model.results.contains { $0.path == "Disk1/Music/y.flac" } })

        await model.setScheduleEnabled(model.schedules[0], false)
        #expect(model.schedules.first?.nextRunAt == nil)

        // The copy goes away: the run is skipped and nothing is removed.
        try FileManager.default.removeItem(atPath: copy)
        await model.runSchedule(model.schedules[0])
        #expect(model.schedules.first?.lastStatus == "skipped")
        #expect(model.schedules.first?.lastRunNeedsAttention == true)
        #expect(model.results.contains { $0.path == "Disk1/Music/y.flac" })

        // It follows a rename, and a disk schedule can't be saved without its folder.
        await model.renameCollection(music, to: "Songs")
        #expect(model.schedules.first?.collection == "Songs")
        var diskDraft = ScheduleDraft(node: model.diskNodes[0])
        diskDraft.path = "/nonexistent/disk"
        await #expect(throws: APIError.self) { try await model.saveSchedule(diskDraft.request) }

        await model.deleteSchedule(model.schedules[0])
        #expect(model.schedules.isEmpty)
    }

    @Test func moveCollectionBetweenDisksAndBack() async throws {
        let (model, _) = try await connectedModel()
        defer { model.disconnect() }
        try await model.startIndex(IndexRequest(disk: "Disk2", mountPath: try makeDisk(["Docs/d.txt": "d"])))
        #expect(await eventually { model.diskNodes.count == 2 })

        let movies = try #require(model.diskNodes[0].collections.first { $0.label == "Movies" })
        #expect(model.moveTargets(for: movies) == ["Disk2"])
        #expect(model.collection(db: movies.db, id: movies.id) == movies)

        model.sidebarSelection = .collection(disk: "Disk1", collection: "Movies")
        let moved = try #require(await model.moveCollection(movies, toDisk: "Disk2"))
        #expect(moved.id == movies.id && moved.diskLabel == "Disk2")
        #expect(model.actionError == nil)
        // The filter follows the collection to its new disk.
        #expect(model.sidebarSelection == .collection(disk: "Disk2", collection: "Movies"))
        #expect(model.diskNodes.map { $0.collections.map(\.label) } == [["Backup", "Music"], ["Docs", "Movies"]])
        #expect(await eventually { model.results.map(\.path).sorted() == ["Disk2/Movies", "Disk2/Movies/a.mkv", "Disk2/Movies/b.mkv"] })

        // Moving back (what Undo does) restores the original paths.
        let back = try #require(await model.moveCollection(moved, toDisk: "Disk1"))
        #expect(back.diskLabel == "Disk1")
        #expect(model.sidebarSelection == .collection(disk: "Disk1", collection: "Movies"))
        #expect(await eventually { model.results.map(\.path).sorted() == ["Disk1/Movies", "Disk1/Movies/a.mkv", "Disk1/Movies/b.mkv"] })
    }

    @Test func moveCollectionConflictReportsError() async throws {
        let (model, _) = try await connectedModel()
        defer { model.disconnect() }
        try await model.startIndex(IndexRequest(disk: "Disk2", mountPath: try makeDisk(["Music/y.flac": "y"])))
        #expect(await eventually { model.diskNodes.count == 2 })

        let music = try #require(model.diskNodes[0].collections.first { $0.label == "Music" })
        // The UI knows about the clash before asking the server: the disk is
        // still listed (so the menu can say why) but flagged.
        #expect(model.moveTargets(for: music) == ["Disk2"])
        #expect(model.moveConflict(for: music, to: "Disk2")?.contains("already has a collection named") == true)
        let movies = try #require(model.diskNodes[0].collections.first { $0.label == "Movies" })
        #expect(model.moveConflict(for: movies, to: "Disk2") == nil)

        // The server refuses it too, if it's attempted anyway.
        #expect(await model.moveCollection(music, toDisk: "Disk2") == nil)
        #expect(model.actionError?.contains("already has a collection named") == true)
        #expect(model.diskNodes[0].collections.contains { $0.label == "Music" })
    }

    @Test func diskRemembersExcludesAcrossRuns() async throws {
        let (model, _) = try await connectedModel()
        defer { model.disconnect() }
        #expect(model.info?.defaultExcludes == [])
        // Started for this connection (--stdin-watch): it says it won't
        // outlive the app, so the Index sheet warns.
        #expect(model.info?.persistent == false)
        #expect(model.info?.user?.isEmpty == false)

        let root = try makeDisk(["Pics/a.jpg": "a", "Pics/.stignore": "x", "Pics/.snapshots/s.jpg": "s"])
        var draft = IndexDraft()
        draft.disk = "Pics Disk"
        draft.mountPath = root
        draft.excludes = ".stignore, .snapshots"
        try await model.startIndex(draft.request)
        #expect(await eventually { model.jobs.first?.state == .done })
        #expect(model.jobs.first?.stats?.excludes == [".stignore", ".snapshots"])

        // The disk now carries them, and a reindex sheet pre-fills them.
        #expect(await eventually { model.diskNodes.contains { $0.label == "Pics Disk" } })
        let node = try #require(model.diskNodes.first { $0.label == "Pics Disk" })
        #expect(node.disks.first?.excludes == [".stignore", ".snapshots"])
        #expect(IndexDraft(node: node).excludes == ".stignore, .snapshots")

        model.query = "stignore"
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(model.results.isEmpty, "the excluded file isn't indexed")
    }

    /// On a slow link, everything after the first request loads in one
    /// round trip, not one per request.
    @Test func slowLinkLoadsInParallel() async throws {
        let delay = 0.4
        let db = scratchDB()
        // Index first, without the delay.
        let seed = AppModel()
        let seedServer = ServeTransport(dbPath: db)
        seed.connect(seedServer)
        #expect(await eventually { seed.status == .connected })
        try await seed.startIndex(IndexRequest(disk: "Disk1", mountPath: try makeDisk(sampleDisk)))
        #expect(await eventually { seed.jobs.first?.state == .done })
        seed.disconnect()

        let server = ServeTransport(dbPath: db)
        server.stdinWatch = false // so it serves schedules too
        let model = AppModel()
        model.connect(SlowTransport(server, delay: delay))
        defer { model.disconnect() }
        #expect(await eventually(timeout: 20) { !model.connectTimings.isEmpty }, "status: \(model.status)")
        let info = try #require(model.connectTimings["info"])
        let load = try #require(model.connectTimings["load"])
        #expect(info >= delay)
        // Disks, collections, jobs and schedules together: about one delay.
        // One after another they would take three or more.
        #expect(load < delay * 2.2, "load took \(load)s")
        #expect(model.diskNodes.count == 1 && model.schedulesAvailable)
        #expect(await eventually { model.results.count == 7 })
    }

    /// The last sidebar and results are shown at once on the next launch,
    /// and can be searched before (or without) a connection.
    @Test func snapshotShowsLastResultsAndFiltersOffline() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("di-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (first, _) = try await connectedModel()
        first.snapshotDirectory = dir
        // Reconnect with a cache key so this connection's state is saved.
        let db = (first.transport as? ServeTransport)?.dbPath ?? ""
        first.connect(ServeTransport(dbPath: db), cacheKey: "srv")
        #expect(await eventually { first.status == .connected && first.results.count == 7 })
        #expect(await eventually { FileManager.default.fileExists(atPath: dir.appendingPathComponent("srv.json").path) })
        first.disconnect()

        let unreachable = ConnectionFailure("offline", isTransient: true, reason: .unreachable)
        let model = AppModel()
        model.snapshotDirectory = dir
        model.connect(FlakyTransport(ServeTransport(dbPath: db), failures: 100, error: unreachable), cacheKey: "srv")
        defer { model.disconnect() }
        #expect(model.showingSnapshot != nil)
        #expect(model.diskNodes.map(\.label) == ["Disk1"])
        #expect(model.results.count == 7)

        model.query = "mkv"
        #expect(model.provisional)
        #expect(model.results.map(\.name).sorted() == ["a.mkv", "a.mkv", "b.mkv"])
        model.sidebarSelection = .collection(disk: "Disk1", collection: "Movies")
        #expect(model.results.map(\.name).sorted() == ["a.mkv", "b.mkv"])
        // Shorter still narrows the saved (unfiltered) results: the folder
        // itself matches now.
        model.query = "m"
        #expect(model.results.map(\.name).sorted() == ["Movies", "a.mkv", "b.mkv"])
        #expect(await eventually { if case .waiting = model.status { return true } else { return false } })
    }

    /// Typing more narrows the results at once; the server's answer follows.
    @Test func typingNarrowsLocallyFirst() async throws {
        let (model, transport) = try await connectedModel()
        defer { model.disconnect() }
        model.query = "fla"
        #expect(model.provisional)
        #expect(model.results.map(\.name) == ["x.flac"])
        #expect(await eventually { !model.provisional })
        #expect(model.results.map(\.name) == ["x.flac"])
        _ = transport
    }

    /// After a network change, a connection that no longer answers is
    /// replaced at once, and a pending retry happens now.
    @Test func networkChangeChecksTheConnection() async throws {
        let server = ServeTransport(dbPath: scratchDB())
        let endpoint = try await server.connect()
        let model = AppModel()
        // The model can't see this server die, like a tunnel over a network
        // that has gone away.
        model.connect(FixedTransport(endpoint))
        defer { model.disconnect() }
        #expect(await eventually { model.status == .connected })
        await model.networkChanged()
        #expect(model.status == .connected, "still answering")

        server.crash()
        await model.networkChanged()
        #expect({ if case .reconnecting = model.status { return true } else { return false } }(), "status: \(model.status)")
        model.disconnect()

        let unreachable = ConnectionFailure("offline", isTransient: true, reason: .unreachable)
        let flaky = FlakyTransport(ServeTransport(dbPath: scratchDB()), failures: 1, error: unreachable)
        AppModel.maxRetryDelay = 30
        defer { AppModel.maxRetryDelay = 30 }
        model.connect(flaky)
        #expect(await eventually { if case .waiting = model.status { return true } else { return false } })
        await model.networkChanged()
        #expect(await eventually(timeout: 5) { model.status == .connected }, "retried without waiting")
    }

    @Test func reconnectsAfterServerDies() async throws {
        let (model, transport) = try await connectedModel()
        defer { model.disconnect() }

        transport.crash()
        #expect(await eventually { transport.launches == 2 && model.status == .connected }, "status: \(model.status)")

        // The new connection is live: the index is still there and searchable.
        #expect(model.diskNodes.map(\.label) == ["Disk1"])
        model.query = "flac"
        #expect(await eventually { model.results.map(\.name) == ["x.flac"] })
    }

    @Test func secondClientSeesRunningJobFinish() async throws {
        let model = AppModel()
        let transport = ServeTransport(dbPath: scratchDB())
        model.connect(transport)
        #expect(await eventually { model.status == .connected })
        defer { model.disconnect() }

        var big: [String: String] = [:]
        for i in 0..<3000 { big["Coll\(i % 3)/dir\(i % 40)/file\(i).txt"] = "x" }
        try await model.startIndex(IndexRequest(disk: "Big", mountPath: try makeDisk(big)))

        // A second client attaching mid-run (like the app reconnecting to a
        // server) picks the job up from the server and follows it to the end.
        let other = AppModel()
        other.connect(FixedTransport(try #require(transport.endpoint)))
        defer { other.disconnect() }
        #expect(await eventually { other.status == .connected })
        #expect(await eventually { other.jobs.count == 1 })
        #expect(await eventually(timeout: 60) { other.jobs.first?.state == .done })
        #expect(await eventually { other.diskNodes.map(\.label) == ["Big"] })
        #expect(other.jobs.first?.stats?.added ?? 0 > 3000)
    }

    @Test func cancelStopsAJob() async throws {
        let model = AppModel()
        model.connect(ServeTransport(dbPath: scratchDB()))
        #expect(await eventually { model.status == .connected })
        defer { model.disconnect() }

        var big: [String: String] = [:]
        for i in 0..<3000 { big["C/d\(i % 40)/f\(i).txt"] = "x" }
        try await model.startIndex(IndexRequest(disk: "Big", mountPath: try makeDisk(big)))
        let id = try #require(model.jobs.first?.id)
        await model.cancelJob(id)
        // The run may legitimately win the race and finish first.
        #expect([JobState.cancelled, .done].contains(model.jobs.first?.state))
        #expect(model.runningJobs.isEmpty)
    }

    @Test func startIndexRejectsBadMountPath() async throws {
        let model = AppModel()
        model.connect(ServeTransport(dbPath: scratchDB()))
        #expect(await eventually { model.status == .connected })
        defer { model.disconnect() }
        await #expect(throws: APIError.self) {
            try await model.startIndex(IndexRequest(disk: "D", mountPath: "/does/not/exist"))
        }
        #expect(model.jobs.isEmpty)
    }

    @Test func waitsAndRetriesWhileTheNetworkIsDown() async throws {
        AppModel.maxRetryDelay = 0.1
        defer { AppModel.maxRetryDelay = 30 }
        let model = AppModel()
        let flaky = FlakyTransport(ServeTransport(dbPath: scratchDB()), failures: 3,
                                   error: ConnectionFailure("Can\u{2019}t reach host: Could not resolve hostname", isTransient: true))
        var sawWaiting = false
        model.connect(flaky)
        #expect(await eventually {
            if case .waiting(let m) = model.status, m.contains("resolve") { sawWaiting = true }
            return model.status == .connected
        })
        defer { model.disconnect() }
        #expect(sawWaiting, "shows why it's waiting while retrying")
        #expect(flaky.attempts == 4)
    }

    @Test func stopsOnProblemsTheUserMustFix() async throws {
        AppModel.maxRetryDelay = 0.1
        defer { AppModel.maxRetryDelay = 30 }
        let model = AppModel()
        let flaky = FlakyTransport(ServeTransport(dbPath: scratchDB()), failures: 1,
                                   error: ConnectionFailure("host refused the login: Permission denied (publickey)", isTransient: false))
        model.connect(flaky)
        #expect(await eventually {
            if case .failed = model.status { return true }
            return false
        })
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(flaky.attempts == 1, "no automatic retries")

        // "Try Again" connects once the problem is fixed.
        model.retryNow()
        #expect(await eventually { model.status == .connected })
        model.disconnect()
    }

    /// The server restarts (e.g. a redeploy) while the tunnel stays up, so the
    /// app never sees a disconnect. The running job's stream breaks; the app
    /// asks about it, the new server doesn't know it, so it's shown as
    /// interrupted instead of running forever.
    @Test func jobLostToServerRestartIsMarkedInterrupted() async throws {
        AppModel.jobRecheckDelay = 0.1
        AppModel.jobRecheckAttempts = 100
        defer { AppModel.jobRecheckDelay = 2; AppModel.jobRecheckAttempts = 15 }
        let server = ServeTransport(dbPath: scratchDB(), port: try freePort(), token: "t")
        let endpoint = try await server.connect()
        defer { server.disconnect() }
        let model = AppModel()
        model.connect(FixedTransport(endpoint))
        #expect(await eventually { model.status == .connected })
        defer { model.disconnect() }

        var big: [String: String] = [:]
        for i in 0..<3000 { big["C/d\(i % 40)/f\(i).txt"] = "x" }
        try await model.startIndex(IndexRequest(disk: "Big", mountPath: try makeDisk(big)))
        server.crash()
        _ = try await server.connect()   // same port and token: a restart

        #expect(await eventually { model.jobs.first?.state == .interrupted })
        #expect(model.jobs.first?.error?.contains("server restarted") == true)
        #expect(model.runningJobs.isEmpty)
        #expect(model.status == .connected)

        // Refreshing from the (new) server keeps it listed as interrupted.
        await model.refreshJobs()
        #expect(model.jobs.first?.state == .interrupted)
    }

    @Test func jobWithServerGoneIsEventuallyMarkedLost() async throws {
        AppModel.jobRecheckDelay = 0.05
        AppModel.jobRecheckAttempts = 5
        defer { AppModel.jobRecheckDelay = 2; AppModel.jobRecheckAttempts = 15 }
        let server = ServeTransport(dbPath: scratchDB())
        let endpoint = try await server.connect()
        let model = AppModel()
        model.connect(FixedTransport(endpoint))
        #expect(await eventually { model.status == .connected })
        defer { model.disconnect() }

        var big: [String: String] = [:]
        for i in 0..<3000 { big["C/d\(i % 40)/f\(i).txt"] = "x" }
        try await model.startIndex(IndexRequest(disk: "Big", mountPath: try makeDisk(big)))
        server.disconnect()

        #expect(await eventually { model.jobs.first?.state == .interrupted })
        #expect(model.jobs.first?.error?.contains("Lost contact") == true)
    }

    @Test func setUpAServerThatIsNotRunning() async throws {
        AppModel.maxRetryDelay = 0.1
        defer { AppModel.maxRetryDelay = 30 }
        let model = AppModel()
        let fresh = InstallableTransport(ServeTransport(dbPath: scratchDB()))
        model.connect(fresh)
        defer { model.disconnect() }

        // The UI can offer "Set Up" because it knows why it's waiting.
        #expect(await eventually { model.lastFailure?.reason == .notRunning })
        if case .waiting = model.status {} else { Issue.record("expected waiting, got \(model.status)") }
        #expect(model.serverManager != nil)

        await model.installServer()
        guard case .done(let report) = model.install else {
            Issue.record("install didn't finish: \(model.install)")
            return
        }
        #expect(report.lingerCommand == "sudo loginctl enable-linger me")
        #expect(await eventually { model.status == .connected })
        #expect(model.lastFailure == nil)
        model.dismissInstall()
        #expect(model.install == .idle)
    }

    @Test func unreachableServerKeepsWaiting() async throws {
        AppModel.maxRetryDelay = 0.1
        defer { AppModel.maxRetryDelay = 30 }
        let model = AppModel()
        // Nothing listens on port 9 (discard) on loopback: connection refused,
        // which is a network problem, so the app waits rather than giving up.
        model.connect(FixedTransport(Endpoint(baseURL: URL(string: "http://127.0.0.1:9/")!)))
        #expect(await eventually {
            if case .waiting = model.status { return true }
            return false
        })
        model.disconnect()
    }

    @Test func untrustedHostKeyAsksThenConnects() async throws {
        let transport = UntrustedTransport(ServeTransport(dbPath: scratchDB()))
        let model = AppModel()
        model.connect(transport)
        #expect(await eventually {
            if case .failed = model.status { return true }
            return false
        })
        let problem = try #require(model.hostKeyProblem)
        #expect(model.hostKeyTruster != nil)

        // Trying again doesn't loop on a key only the user can accept.
        model.retryNow()
        #expect(await eventually { transport.attempts == 2 })
        #expect(await eventually {
            if case .failed = model.status { return true }
            return false
        })

        transport.rejectTrust = true
        await model.trustHostKey(problem)
        #expect(model.status == .failed("new.local presented a different key"))
        #expect(model.hostKeyProblem == nil, "a failed trust shows its error, not the same prompt")

        transport.rejectTrust = false
        await model.trustHostKey(problem)
        #expect(await eventually { model.status == .connected }, "status: \(model.status)")
        #expect(transport.trusted == [problem])
        #expect(model.hostKeyProblem == nil)
        model.disconnect()
    }
}
