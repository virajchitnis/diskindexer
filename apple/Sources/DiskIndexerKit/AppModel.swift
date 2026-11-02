import Foundation
import Observation
import SwiftUI

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

    // Metadata
    public private(set) var diskNodes: [DiskNode] = []

    // Search state
    public var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    public var typeFilter: TypeFilter = .all { didSet { if typeFilter != oldValue { scheduleSearch(debounce: false) } } }
    public var sidebarSelection: SidebarItem? = .allDisks { didSet { if sidebarSelection != oldValue { scheduleSearch(debounce: false) } } }
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
    public func connect(_ transport: Transport) {
        disconnect()
        self.transport = transport
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
        jobs = []
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
                let endpoint = try await transport.connect()
                let client = APIClient(endpoint: endpoint)
                let info = try await client.info()
                guard info.apiVersion == supportedAPIVersion else {
                    throw ConnectionFailure("Server speaks API v\(info.apiVersion); this app needs v\(supportedAPIVersion). Update diskindexer on \(transport.displayName).", isTransient: false)
                }
                guard !Task.isCancelled, self.transport === transport else { return }
                self.client = client
                self.info = info
                status = .connected
                await refreshMetadata()
                await refreshJobs()
                scheduleSearch(debounce: false)
                return
            } catch {
                guard !Task.isCancelled, self.transport === transport else { return }
                let message = error.localizedDescription
                let versionMismatch = (error as? ConnectionFailure)?.isTransient == false && message.contains("API v")
                let retry = !versionMismatch && (retrying || alwaysRetry || error.isTransientConnectionError)
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

    /// Longest wait between connection attempts. A var so tests can shorten it.
    static var maxRetryDelay: TimeInterval = 30

    // MARK: Metadata

    public func refreshMetadata() async {
        guard let client else { return }
        do {
            async let disks = client.disks()
            async let colls = client.collections()
            let (d, c) = try await (disks, colls)
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
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: Search

    public func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        guard let client else { return }
        var req = SearchRequest(query: query, type: typeFilter)
        switch sidebarSelection {
        case .disk(let d): req.disk = d
        case .collection(let d, let c): req.disk = d; req.collection = c
        default: break
        }
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
                setResults(resp.results)
            } catch {
                if Task.isCancelled { return }
                searchError = error.localizedDescription
            }
        }
    }

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

    // MARK: Management

    private func perform(_ action: (APIClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await action(client)
        } catch {
            actionError = error.localizedDescription
        }
        await refreshMetadata()
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
            jobs = (server + lost).sorted { $0.startedAt > $1.startedAt }
            for job in jobs where job.state == .running { watch(job.id) }
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
        let wasRunning = jobs.first { $0.id == job.id }?.state == .running
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
