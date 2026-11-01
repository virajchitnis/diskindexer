import Foundation
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
    private(set) var endpoint: Endpoint?
    private(set) var launches = 0
    private var process: Process?
    private var stopping = false

    init(dbPath: String) {
        self.dbPath = dbPath
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
        let token = UUID().uuidString
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try Self.binaryPath())
        p.arguments = ["serve", "--listen", "127.0.0.1:0", "--stdin-watch", "--db", dbPath]
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
    }
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
private func connectedModel() async throws -> (AppModel, ServeTransport) {
    let model = AppModel()
    let transport = ServeTransport(dbPath: scratchDB())
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

    @Test func unreachableServerReportsFailure() async throws {
        let model = AppModel()
        // Nothing listens on port 9 (discard) on loopback.
        model.connect(FixedTransport(Endpoint(baseURL: URL(string: "http://127.0.0.1:9/")!)))
        #expect(await eventually {
            if case .failed = model.status { return true }
            return false
        })
    }
}
