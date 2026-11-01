import Foundation
import Observation
import SwiftUI

public enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(String)
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

    // Metadata
    public private(set) var diskNodes: [DiskNode] = []

    // Search state
    public var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    public var typeFilter: TypeFilter = .all { didSet { if typeFilter != oldValue { scheduleSearch(debounce: false) } } }
    public var sidebarSelection: SidebarItem? = .allDisks { didSet { if sidebarSelection != oldValue { scheduleSearch(debounce: false) } } }
    public private(set) var results: [FileItem] = []
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

    private func establish(retrying: Bool) async {
        guard let transport else { return }
        var delay: UInt64 = 1
        while !Task.isCancelled {
            do {
                if retrying { transport.disconnect() }
                let endpoint = try await transport.connect()
                let client = APIClient(endpoint: endpoint)
                let info = try await client.info()
                guard info.apiVersion == supportedAPIVersion else {
                    throw APIError(status: 0, message: "Server speaks API v\(info.apiVersion); this app needs v\(supportedAPIVersion). Update diskindexer on \(transport.displayName).")
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
                guard !Task.isCancelled else { return }
                if !retrying {
                    status = .failed(error.localizedDescription)
                    transport.disconnect()
                    return
                }
                status = .reconnecting(error.localizedDescription)
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            }
        }
    }

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
        results = files.sorted(using: sortOrder)
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
            jobs = try await client.jobs()
            for job in jobs where job.state == .running { watch(job.id) }
        } catch {
            actionError = error.localizedDescription
        }
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

    private func watch(_ id: String) {
        guard jobWatchers[id] == nil, let client else { return }
        jobWatchers[id] = Task {
            defer { jobWatchers[id] = nil }
            do {
                for try await job in client.jobEvents(id) {
                    update(job)
                }
            } catch {
                // Stream dropped (e.g. tunnel died). Reconnecting re-attaches.
            }
        }
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
