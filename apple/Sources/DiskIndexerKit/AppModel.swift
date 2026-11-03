import Foundation
import Observation
import os
import SwiftUI

let connectLog = Logger(subsystem: "com.virajchitnis.diskindexer", category: "connect")

public enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    /// Never connected yet; retrying a transient failure (e.g. the network
    /// or Tailscale isn't up). Carries the latest error.
    case waiting(String)
    /// Was connected; the connection dropped and is being retried.
    case reconnecting(String)
    /// Gave up: something the user has to fix (host key, login, version).
    case failed(String)
}

public enum SidebarItem: Hashable {
    case allDisks
    case disk(String)
    case collection(disk: String, collection: String)
}

/// One disk label in the sidebar, merged across index files.
public struct DiskNode: Identifiable, Hashable {
    public var label: String
    public var disks: [Disk]
    public var collections: [Collection]
    public var id: String { label }

    /// Best guess at the mount path: the common parent of the collection roots.
    public var guessedMountPath: String? {
        let parents = Set(collections.map { ($0.rootPath as NSString).deletingLastPathComponent })
        return parents.count == 1 ? parents.first : nil
    }
}

@MainActor
@Observable
public final class AppModel {
    // Connection
    public private(set) var status: ConnectionStatus = .disconnected
    public private(set) var info: ServerInfo?
    public private(set) var transport: Transport?
    private(set) var client: APIClient?
    private var connectTask: Task<Void, Never>?
    /// When the current wait between connection attempts ends, so the UI can
    /// say "retrying in 8s".
    public private(set) var nextAttempt: Date?
    /// The most recent connection failure, so the UI can offer to install or
    /// update diskindexer when that's the problem.
    public private(set) var lastFailure: ConnectionFailure?
    /// How long each phase of the last connect took, in seconds: "connect"
    /// (the transport), "info" (one round trip) and "load" (sidebar, jobs
    /// and schedules). Also logged, under the "connect" category.
    public private(set) var connectTimings: [String: TimeInterval] = [:]

    /// Where to keep each connection's last sidebar and results, so the app
    /// shows them straight away on the next launch. nil turns this off.
    public var snapshotDirectory: URL?
    private var snapshotKey: String?
    /// The sidebar and results come from a snapshot saved at this time, not
    /// (yet) from the server.
    public private(set) var showingSnapshot: Date?

    /// The server runs an older diskindexer than this app bundles: the UI
    /// offers to update it.
    public private(set) var serverUpdate: (current: String, available: String)?
    public private(set) var install: InstallState = .idle

    public enum InstallState: Equatable {
        case idle
        case running([String])
        case done(InstallReport)
        case failed(String, [String])
    }

    /// The transport, if it can install diskindexer on its server.
    public var serverManager: ServerManaging? { transport as? ServerManaging }

    /// The transport, if it can trust a server's host key itself.
    public var hostKeyTruster: HostKeyTrusting? { transport as? HostKeyTrusting }
    /// The host key the last connect stopped on, if any.
    public var hostKeyProblem: HostKeyProblem? { lastFailure?.hostKey }

    // Metadata
    public private(set) var diskNodes: [DiskNode] = []

    // Search state
    public var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    public var typeFilter: TypeFilter = .all { didSet { if typeFilter != oldValue { scheduleSearch(debounce: false) } } }
    public var sidebarSelection: SidebarItem? = .allDisks { didSet { if sidebarSelection != oldValue { scheduleSearch(debounce: false) } } }
    /// The results are filtered locally from earlier ones while the server's
    /// answer is on its way (or while not connected).
    public private(set) var provisional = false
    /// The last results the server sent, and what they were for.
    private var baseline: (request: SearchRequest, files: [FileItem], capped: Bool)?
    public private(set) var results: [FileItem] = []
    /// Bumped whenever `results` is replaced by a different result set. The
    /// results table is rebuilt on each change instead of having SwiftUI
    /// insert hundreds of rows into the live table, which makes AppKit warn
    /// about a reentrant NSTableView delegate (a future assert).
    public private(set) var resultsGeneration = 0
    public private(set) var capped = false
    public private(set) var searching = false
    public private(set) var searchError: String?
    public var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\.name)] { didSet { applySort() } }
    public var selection: Set<FileItem.ID> = []
    public private(set) var duplicateKeys: Set<String> = []
    private var searchTask: Task<Void, Never>?

    // Schedules
    public private(set) var schedules: [Schedule] = []

    // Jobs
    public private(set) var jobs: [Job] = []
    private var jobWatchers: [String: Task<Void, Never>] = [:]

    /// Most recent error from a management action, shown as an alert.
    public var actionError: String?

    /// Platform hook for a native folder picker, used when the transport is local.
    public var pickLocalFolder: (() -> String?)?

    public init() {}

    public var selectedFile: FileItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return results.first { $0.id == id }
    }

    public var runningJobs: [Job] { jobs.filter { $0.state == .running } }

    // MARK: Connection

    /// Connects through transport, replacing any current connection. If the
    /// transport later reports a disconnect, reconnects with backoff.
    /// `cacheKey` names the connection's snapshot (see snapshotDirectory).
    public func connect(_ transport: Transport, cacheKey: String? = nil) {
        disconnect()
        self.transport = transport
        snapshotKey = cacheKey
        loadSnapshot()
        transport.onDisconnect = { [weak self, weak transport] reason in
            Task { @MainActor in
                guard let self, let transport, self.transport === transport else { return }
                self.handleDisconnect(reason)
            }
        }
        status = .connecting
        connectTask = Task { await self.establish(retrying: false) }
    }

    public func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        stopWatchingJobs()
        searchTask?.cancel()
        transport?.onDisconnect = nil
        transport?.disconnect()
        transport = nil
        client = nil
        info = nil
        status = .disconnected
        diskNodes = []
        results = []
        baseline = nil
        provisional = false
        showingSnapshot = nil
        snapshot = nil
        jobs = []
        schedules = []
    }

    private func handleDisconnect(_ reason: String) {
        guard status == .connected else { return }
        client = nil
        stopWatchingJobs()
        status = .reconnecting(reason)
        connectTask = Task { await self.establish(retrying: true) }
    }

    /// Skips the rest of the wait between connection attempts.
    public func retryNow() {
        guard transport != nil else { return }
        let reconnecting: Bool
        switch status {
        case .waiting: reconnecting = false
        case .reconnecting: reconnecting = true
        case .failed: reconnecting = false; status = .connecting
        default: return
        }
        connectTask?.cancel()
        connectTask = Task { await self.establish(retrying: reconnecting, alwaysRetry: true) }
    }

    /// Connects, retrying with backoff. A first connection only retries
    /// transient failures (see ConnectionFailure); a reconnect, or an explicit
    /// "try now", retries everything except a version mismatch.
    private func establish(retrying: Bool, alwaysRetry: Bool = false) async {
        guard let transport else { return }
        var delay = min(1, Self.maxRetryDelay)
        var attempted = false
        while !Task.isCancelled {
            do {
                if retrying || attempted { transport.disconnect() }
                attempted = true
                nextAttempt = nil
                var started = Date()
                let endpoint = try await transport.connect()
                var timings = ["connect": Date().timeIntervalSince(started)]
                started = Date()
                var client = APIClient(endpoint: endpoint)
                let info = try await client.info()
                let latency = Date().timeIntervalSince(started)
                timings["info"] = latency
                if latency > 0.25 {
                    client = APIClient(endpoint: endpoint, latency: latency)
                }
                guard info.apiVersion == supportedAPIVersion else {
                    throw ConnectionFailure("Server speaks API v\(info.apiVersion); this app needs v\(supportedAPIVersion). Update diskindexer on \(transport.displayName).",
                                            isTransient: false, reason: .incompatibleVersion)
                }
                guard !Task.isCancelled, self.transport === transport else { return }
                self.client = client
                self.info = info
                lastFailure = nil
                serverUpdate = Self.updateAvailable(server: info.version, bundled: serverManager?.bundledVersion)
                status = .connected
                scheduleSearch(debounce: false)
                // All at once: on a slow link each request is a round trip.
                started = Date()
                async let metadata: Void = refreshMetadata()
                async let jobs: Void = refreshJobs()
                async let schedules: Void = refreshSchedules()
                _ = await (metadata, jobs, schedules)
                timings["load"] = Date().timeIntervalSince(started)
                connectTimings = timings
                connectLog.notice("""
                    connected to \(transport.displayName, privacy: .public): \
                    transport \(timings["connect"] ?? 0, format: .fixed(precision: 3))s, \
                    round trip \(latency, format: .fixed(precision: 3))s, \
                    load \(timings["load"] ?? 0, format: .fixed(precision: 3))s
                    """)
                return
            } catch {
                guard !Task.isCancelled, self.transport === transport else { return }
                let message = error.localizedDescription
                lastFailure = error as? ConnectionFailure ?? ConnectionFailure(message, isTransient: error.isTransientConnectionError)
                // A version mismatch or an untrusted host key won't fix itself.
                let needsUser = lastFailure?.reason == .incompatibleVersion || lastFailure?.hostKey != nil
                let retry = !needsUser && (retrying || alwaysRetry || error.isTransientConnectionError)
                guard retry else {
                    status = .failed(message)
                    transport.disconnect()
                    return
                }
                status = retrying ? .reconnecting(message) : .waiting(message)
                nextAttempt = Date().addingTimeInterval(delay)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, Self.maxRetryDelay)
            }
        }
    }

    /// Call when the device's network changes (Wi-Fi to hotspot, VPN up,
    /// waking from sleep). A pending retry happens now instead of after its
    /// wait. A live connection is checked straight away: over Tailscale it
    /// usually survives the change, otherwise it's replaced without waiting
    /// for ssh's keepalive to give up.
    public func networkChanged() async {
        switch status {
        case .waiting, .reconnecting:
            retryNow()
        case .connected:
            guard let client else { return }
            do {
                try await client.ping(timeout: 4)
            } catch {
                guard self.client === client, status == .connected else { return }
                connectLog.notice("connection lost after a network change")
                handleDisconnect("The network changed and \(transport?.displayName ?? "the server") stopped answering.")
            }
        default:
            break
        }
    }

    private var networkWatcher: NetworkWatcher?

    /// Calls networkChanged() whenever the device's network changes.
    public func watchNetwork() {
        guard networkWatcher == nil else { return }
        networkWatcher = NetworkWatcher { [weak self] in
            Task { @MainActor in await self?.networkChanged() }
        }
    }

    /// Whether the bundled version is newer than the server's. Untagged
    /// development builds don't compare, so they never prompt.
    nonisolated static func updateAvailable(server: String, bundled: String?) -> (current: String, available: String)? {
        guard let bundled, let b = ServerVersion(bundled), let s = ServerVersion(server), s < b else { return nil }
        return (server, bundled)
    }

    /// Installs or updates diskindexer on the server, then reconnects. The
    /// UI asks for confirmation first (and warns about running jobs, which a
    /// restart stops).
    public func installServer() async {
        guard let manager = serverManager, let transport else { return }
        if case .running = install { return }
        var log: [String] = []
        install = .running(log)
        let lines = AsyncStream<String> { cont in
            Task.detached {
                do {
                    let report = try await manager.installServer { line in cont.yield(line) }
                    await MainActor.run { self.install = .done(report) }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        if case .running(let l) = self.install { self.install = .failed(message, l) }
                    }
                }
                cont.finish()
            }
        }
        for await line in lines {
            log.append(line)
            if case .running = install { install = .running(log) }
        }
        if case .done = install {
            serverUpdate = nil
            connect(transport)
        }
    }

    /// Trusts the host key the last connect stopped on, then connects. The
    /// UI shows the fingerprint first (and asks again for a changed key).
    public func trustHostKey(_ problem: HostKeyProblem) async {
        guard let truster = hostKeyTruster, let transport else { return }
        status = .connecting
        do {
            try await truster.trustHostKey(problem)
        } catch {
            guard self.transport === transport else { return }
            let message = error.localizedDescription
            lastFailure = ConnectionFailure(message, isTransient: false)
            status = .failed(message)
            return
        }
        guard self.transport === transport else { return }
        lastFailure = nil
        connect(transport)
    }

    public func dismissInstall() {
        if case .running = install { return }
        install = .idle
    }

    /// Longest wait between connection attempts. A var so tests can shorten it.
    static var maxRetryDelay: TimeInterval = 30

    // MARK: Metadata

    public func refreshMetadata() async {
        guard let client else { return }
        do {
            async let disks = client.disks()
            async let colls = client.collections()
            let (d, c) = try await (disks, colls)
            applyMetadata(disks: d, collections: c)
            saveSnapshot(disks: d, collections: c)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func applyMetadata(disks d: [Disk], collections c: [Collection]) {
        do {
            var nodes: [String: DiskNode] = [:]
            for disk in d {
                nodes[disk.label, default: DiskNode(label: disk.label, disks: [], collections: [])].disks.append(disk)
            }
            for coll in c {
                nodes[coll.diskLabel, default: DiskNode(label: coll.diskLabel, disks: [], collections: [])].collections.append(coll)
            }
            diskNodes = nodes.values
                .map { var n = $0; n.collections.sort { $0.label.localizedStandardCompare($1.label) == .orderedAscending }; return n }
                .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            // Drop a filter that no longer exists (e.g. after a delete or rename).
            if case let .disk(label) = sidebarSelection, !diskNodes.contains(where: { $0.label == label }) {
                sidebarSelection = .allDisks
            }
            if case let .collection(disk, coll) = sidebarSelection,
               !(diskNodes.first { $0.label == disk }?.collections.contains { $0.label == coll } ?? false) {
                sidebarSelection = .allDisks
            }
        }
    }

    // MARK: Search

    private var currentRequest: SearchRequest {
        var req = SearchRequest(query: query, type: typeFilter)
        switch sidebarSelection {
        case .disk(let d): req.disk = d
        case .collection(let d, let c): req.disk = d; req.collection = c
        default: break
        }
        return req
    }

    public func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        let req = currentRequest
        // Show what can be worked out locally straight away, like mosh's
        // local echo; the server's answer replaces it.
        filterLocally(req)
        guard let client else { return }
        searchTask = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
            searching = true
            defer { if !Task.isCancelled { searching = false } }
            do {
                let resp = try await client.search(req)
                if Task.isCancelled { return }
                searchError = nil
                capped = resp.capped
                provisional = false
                showingSnapshot = nil
                baseline = (req, resp.results, resp.capped)
                setResults(resp.results)
                if req == Self.defaultRequest { saveSnapshot(results: resp.results, capped: resp.capped) }
            } catch {
                if Task.isCancelled { return }
                searchError = error.localizedDescription
            }
        }
    }

    /// Narrows the last server results to `req` when it only narrows what
    /// they were for (more typed, a type or a disk picked), so they are
    /// exactly the matches among them. Otherwise leaves the results alone.
    private func filterLocally(_ req: SearchRequest) {
        guard let base = baseline, base.request != req, Self.narrows(req, base.request) else { return }
        let tokens = req.query.lowercased().split(whereSeparator: \.isWhitespace)
        let files = base.files.filter { f in
            let path = f.path.lowercased()
            return tokens.allSatisfy { path.contains($0) }
                && (req.type != .files || !f.isDir) && (req.type != .dirs || f.isDir)
                && (req.disk == nil || f.diskLabel == req.disk)
                && (req.collection == nil || f.collLabel == req.collection)
        }
        provisional = true
        capped = base.capped && files.count == base.files.count
        setResults(files)
    }

    /// Whether every match for `req` is among the matches for `base`.
    nonisolated static func narrows(_ req: SearchRequest, _ base: SearchRequest) -> Bool {
        let q = req.query.lowercased().trimmingCharacters(in: .whitespaces)
        let b = base.query.lowercased().trimmingCharacters(in: .whitespaces)
        return (b.isEmpty || q.contains(b))
            && (base.type == nil || base.type == .all || base.type == req.type)
            && (base.disk == nil || base.disk == req.disk)
            && (base.collection == nil || base.collection == req.collection)
    }

    /// What the window shows on launch, so the one worth keeping.
    static let defaultRequest = SearchRequest(query: "", type: .all)

    private func setResults(_ files: [FileItem]) {
        var counts: [String: Int] = [:]
        for f in files where !(f.isDir && f.size == 0) {
            counts[f.duplicateKey, default: 0] += 1
        }
        duplicateKeys = Set(counts.filter { $0.value > 1 }.keys)
        let sorted = files.sorted(using: sortOrder)
        // Identical results (e.g. a refresh after a job) keep the table, and
        // with it the scroll position.
        guard sorted != results else { return }
        results = sorted
        resultsGeneration += 1
        selection = selection.filter { id in results.contains { $0.id == id } }
    }

    private func applySort() {
        results.sort(using: sortOrder)
    }

    public func isDuplicate(_ f: FileItem) -> Bool {
        !(f.isDir && f.size == 0) && duplicateKeys.contains(f.duplicateKey)
    }

    // MARK: Snapshots

    struct Snapshot: Codable {
        var savedAt: Date
        var disks: [Disk]
        var collections: [Collection]
        var results: [FileItem]
        var capped: Bool
    }

    private var snapshotURL: URL? {
        guard let dir = snapshotDirectory, let key = snapshotKey else { return nil }
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return dir.appendingPathComponent(String(safe) + ".json")
    }

    private var snapshot: Snapshot?

    /// Shows the connection's last sidebar and results until the server
    /// answers, and lets the results be filtered meanwhile.
    private func loadSnapshot() {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url),
              let snap = try? APIClient.decoder.decode(Snapshot.self, from: data) else { return }
        snapshot = snap
        applyMetadata(disks: snap.disks, collections: snap.collections)
        baseline = (Self.defaultRequest, snap.results, snap.capped)
        capped = snap.capped
        setResults(snap.results)
        showingSnapshot = snap.savedAt
        if currentRequest != Self.defaultRequest { filterLocally(currentRequest) }
    }

    private func saveSnapshot(disks: [Disk]? = nil, collections: [Collection]? = nil,
                              results: [FileItem]? = nil, capped: Bool? = nil) {
        guard let url = snapshotURL else { return }
        var snap = snapshot ?? Snapshot(savedAt: Date(), disks: [], collections: [], results: [], capped: false)
        snap.savedAt = Date()
        if let disks { snap.disks = disks }
        if let collections { snap.collections = collections }
        if let results { snap.results = results }
        if let capped { snap.capped = capped }
        snapshot = snap
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try APIClient.encoder.encode(snap).write(to: url, options: .atomic)
        } catch {
            connectLog.error("saving snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Management

    private func perform(_ action: (APIClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await action(client)
        } catch {
            actionError = error.localizedDescription
        }
        await refreshMetadata()
        await refreshSchedules()
        scheduleSearch(debounce: false)
    }

    public func renameCollection(_ c: Collection, to label: String) async {
        guard let client else { return }
        do {
            try await client.renameCollection(c, to: label)
            // Follow the rename before refreshing, or the refresh sees the old
            // name is gone and resets the filter to all disks.
            if case .collection(c.diskLabel, c.label) = sidebarSelection {
                sidebarSelection = .collection(disk: c.diskLabel, collection: label)
            }
        } catch {
            actionError = error.localizedDescription
        }
        await refreshMetadata()
        await refreshSchedules()
        scheduleSearch(debounce: false)
    }

    /// Disks a collection can be moved to: others in the same index file.
    public func moveTargets(for c: Collection) -> [String] {
        diskNodes
            .filter { $0.label != c.diskLabel && $0.disks.contains { $0.db == c.db } }
            .map(\.label)
    }

    /// Why `c` can't be moved to `disk`, or nil if it can. Collections are
    /// never merged (the index must match the real disk), so a name already
    /// used on the target rules it out. The server enforces the same rule;
    /// this lets the UI say so before the user confirms.
    public func moveConflict(for c: Collection, to disk: String) -> String? {
        guard let node = diskNodes.first(where: { $0.label == disk }),
              node.collections.contains(where: { $0.label == c.label })
        else { return nil }
        return "\u{201C}\(disk)\u{201D} already has a collection named \u{201C}\(c.label)\u{201D}, so this one can't be moved there."
    }

    /// Finds a collection in the sidebar by its index file and ID.
    public func collection(db: String, id: Int64) -> Collection? {
        diskNodes.lazy.flatMap(\.collections).first { $0.db == db && $0.id == id }
    }

    /// Moves a collection to another disk without reindexing. Returns the
    /// collection as it is after the move, or nil (with actionError set) if
    /// the server refused, e.g. because the target has the same name already.
    @discardableResult
    public func moveCollection(_ c: Collection, toDisk disk: String) async -> Collection? {
        guard let client else { return nil }
        var moved: Collection?
        do {
            moved = try await client.moveCollection(c, toDisk: disk)
            // Follow the move before refreshing, as with rename.
            if case .collection(c.diskLabel, c.label) = sidebarSelection {
                sidebarSelection = .collection(disk: disk, collection: c.label)
            }
        } catch {
            actionError = error.localizedDescription
        }
        await refreshMetadata()
        await refreshSchedules()
        scheduleSearch(debounce: false)
        return moved
    }

    public func deleteCollection(_ c: Collection) async {
        await perform { try await $0.deleteCollection(c) }
    }

    public func deleteDisk(_ node: DiskNode) async {
        await perform { client in
            for d in node.disks { try await client.deleteDisk(d) }
        }
    }

    // MARK: Jobs

    public func refreshJobs() async {
        guard let client else { return }
        do {
            let server = try await client.jobs()
            // Jobs we were following that the server no longer knows about
            // were lost in a server restart; keep them, marked as such.
            let known = Set(server.map(\.id))
            let lost = jobs.filter { !known.contains($0.id) && ($0.state == .running || $0.state == .interrupted) }
                .map { Self.interrupted($0, Self.serverRestartedMessage) }
            // A job seen running before and finished now changed the index,
            // even if its own progress stream hasn't said so yet.
            let wasRunning = Set(jobs.filter { $0.state == .running }.map(\.id))
            let finished = server.contains { wasRunning.contains($0.id) && $0.state != .running }
            jobs = (server + lost).sorted { $0.startedAt > $1.startedAt }
            for job in jobs where job.state == .running { watch(job.id) }
            if finished {
                await refreshMetadata()
                await refreshSchedules()
                scheduleSearch(debounce: false)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    static let serverRestartedMessage = "The server restarted, which stopped this run. Files indexed so far were kept; run it again to finish."
    static let lostContactMessage = "Lost contact with the server during this run, so its outcome is unknown. Reconnect to check."

    private static func interrupted(_ job: Job, _ message: String) -> Job {
        guard job.state == .running else { return job }
        var j = job
        j.state = .interrupted
        j.error = message
        return j
    }

    public func startIndex(_ req: IndexRequest) async throws {
        guard let client else { throw APIError(status: 0, message: "Not connected") }
        let job = try await client.startIndex(req)
        jobs.insert(job, at: 0)
        watch(job.id)
    }

    public func cancelJob(_ id: String) async {
        guard let client else { return }
        do {
            update(try await client.cancelJob(id))
        } catch {
            actionError = error.localizedDescription
        }
    }

    public func clearFinishedJobs() {
        jobs.removeAll { $0.state != .running }
    }

    private func update(_ job: Job) {
        // A job first seen already finished (a scheduled run that was quick)
        // changed the index just the same.
        let wasRunning = jobs.first { $0.id == job.id }.map { $0.state == .running } ?? true
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            // A job never goes back to running once it has finished: a
            // progress event already in flight can arrive after the cancel
            // response (or the final event) and would otherwise revive it.
            if jobs[i].state != .running && job.state == .running { return }
            jobs[i] = job
        } else {
            jobs.insert(job, at: 0)
        }
        if wasRunning && job.state != .running {
            Task {
                await refreshMetadata()
                if job.schedule != nil { await refreshSchedules() }
                scheduleSearch(debounce: false)
            }
        }
    }

    /// How long to keep asking about a job whose progress stream broke before
    /// giving up on it. Vars so tests can shorten them.
    static var jobRecheckDelay: TimeInterval = 2
    static var jobRecheckAttempts = 15

    /// Follows a job's progress stream. If the stream ends while the job is
    /// still running (the server restarted, or a request failed) and the
    /// connection itself is fine, asks the server what happened: re-attaches
    /// if the job is still running, marks it interrupted if the server no
    /// longer knows it. A dropped connection cancels this; reconnecting
    /// re-attaches through refreshJobs.
    private func watch(_ id: String) {
        guard jobWatchers[id] == nil, let client else { return }
        jobWatchers[id] = Task {
            defer { jobWatchers[id] = nil }
            var failures = 0
            while !Task.isCancelled, self.client === client {
                do {
                    for try await job in client.jobEvents(id) {
                        update(job)
                    }
                } catch {}
                guard !Task.isCancelled, jobs.first(where: { $0.id == id })?.state == .running else { return }
                do {
                    let job = try await client.job(id)
                    update(job)
                    failures = 0
                    if job.state != .running { return }
                } catch let e as APIError where e.status == 404 {
                    markInterrupted(id, Self.serverRestartedMessage)
                    return
                } catch {
                    failures += 1
                    if failures >= Self.jobRecheckAttempts {
                        markInterrupted(id, Self.lostContactMessage)
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.jobRecheckDelay * 1_000_000_000))
            }
        }
    }

    private func markInterrupted(_ id: String, _ message: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i] = Self.interrupted(jobs[i], message)
    }

    private func stopWatchingJobs() {
        for t in jobWatchers.values { t.cancel() }
        jobWatchers = [:]
    }

    // MARK: Schedules

    /// Whether the server runs schedules. Servers that only live while the
    /// app is connected (and older ones) don't.
    public var schedulesAvailable: Bool { info?.scheduler == true }

    public func refreshSchedules() async {
        guard let client, schedulesAvailable else { return }
        do {
            schedules = try await client.schedules()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// The schedule for a disk (collection nil) or one of its collections.
    public func schedule(disk: String, collection: String? = nil) -> Schedule? {
        schedules.first { $0.disk == disk && ($0.collection ?? "") == (collection ?? "") }
    }

    /// Creates or updates a schedule; throws so the editor can show why.
    public func saveSchedule(_ req: ScheduleRequest, id: Int64? = nil) async throws {
        guard let client else { throw APIError(status: 0, message: "Not connected") }
        _ = try await client.saveSchedule(req, id: id)
        await refreshSchedules()
    }

    public func setScheduleEnabled(_ s: Schedule, _ enabled: Bool) async {
        let req = ScheduleRequest(db: s.db, disk: s.disk, collection: s.collection, path: s.path,
                                  intervalHours: s.intervalHours, at: s.at, enabled: enabled)
        do {
            try await saveSchedule(req, id: s.scheduleID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    public func deleteSchedule(_ s: Schedule) async {
        guard let client else { return }
        do {
            try await client.deleteSchedule(s)
        } catch {
            actionError = error.localizedDescription
        }
        await refreshSchedules()
    }

    /// Runs a schedule now. If it started, its job is followed like any other;
    /// if it was skipped, the schedule says why.
    public func runSchedule(_ s: Schedule) async {
        guard let client else { return }
        do {
            let updated = try await client.runSchedule(s)
            if let id = updated.lastJobId, updated.lastStatus == "running" {
                update(try await client.job(id))
                watch(id)
            }
        } catch {
            actionError = error.localizedDescription
        }
        await refreshSchedules()
    }

    // MARK: Remote filesystem

    public func listDir(_ path: String) async throws -> DirListing {
        guard let client else { throw APIError(status: 0, message: "Not connected") }
        return try await client.listDir(path)
    }

    public func fsRoots() async throws -> [DirEntry] {
        guard let client else { throw APIError(status: 0, message: "Not connected") }
        return try await client.fsRoots()
    }
}
