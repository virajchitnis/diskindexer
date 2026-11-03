import Foundation

// Wire types mirroring internal/api/types.go. Field names match the JSON keys.

public let supportedAPIVersion = 1

public struct ServerInfo: Codable, Sendable {
    public var apiVersion: Int
    public var version: String
    public var hostname: String
    public var os: String
    public var defaultDb: String
    public var dbs: [String]
    /// Excludes every index run applies (server config). Optional: older
    /// servers omit it.
    public var defaultExcludes: [String]?
    /// The account the server runs as.
    public var user: String?
    /// Whether the server keeps running, and finishes index runs, after the
    /// app disconnects. nil when unknown (or an older server).
    public var persistent: Bool?
    /// Whether the server runs schedules; nil for servers without them.
    public var scheduler: Bool?
    /// The server's time zone abbreviation, which schedule times are in.
    public var timeZone: String?
}

public struct Disk: Codable, Hashable, Sendable, Identifiable {
    public var db: String
    public var id: Int64
    public var label: String
    public var description: String
    public var createdAt: Date
    public var lastIndexedAt: Date?
    /// Excludes the disk was last indexed with, beyond the server defaults.
    public var excludes: [String]?
}

public struct Collection: Codable, Hashable, Sendable, Identifiable {
    public var db: String
    public var id: Int64
    public var diskLabel: String
    public var label: String
    public var rootPath: String
    public var lastIndexedAt: Date?
}

public struct FileItem: Codable, Hashable, Sendable, Identifiable {
    public var db: String
    public var fileID: Int64
    public var name: String
    public var path: String
    public var size: Int64
    public var modifiedAt: Date
    public var `extension`: String
    public var isDir: Bool
    public var diskLabel: String
    public var collLabel: String

    /// File IDs are only unique within one index, so qualify with the DB.
    public var id: String { "\(db)#\(fileID)" }

    /// Key used for duplicate highlighting, matching the TUI.
    public var duplicateKey: String { "\(name)|\(size)" }

    enum CodingKeys: String, CodingKey {
        case db, fileID = "id", name, path, size, modifiedAt, `extension`, isDir, diskLabel, collLabel
    }
}

public enum TypeFilter: String, Codable, CaseIterable, Sendable {
    case all, files, dirs

    public var title: String {
        switch self {
        case .all: "All"
        case .files: "Files"
        case .dirs: "Folders"
        }
    }
}

public struct SearchRequest: Codable, Hashable, Sendable {
    public var query: String
    public var disk: String?
    public var collection: String?
    public var type: TypeFilter?
    public var limit: Int?

    public init(query: String, disk: String? = nil, collection: String? = nil, type: TypeFilter? = nil, limit: Int? = nil) {
        self.query = query
        self.disk = disk
        self.collection = collection
        self.type = type
        self.limit = limit
    }
}

public struct SearchResponse: Codable, Sendable {
    public var results: [FileItem]
    public var capped: Bool
}

public struct CollectionSpec: Codable, Hashable, Sendable, Identifiable {
    public var label: String
    public var rootPath: String
    /// Read from rootPath this once, keeping an existing collection's saved
    /// location (e.g. when reading a copy).
    public var keepRootPath: Bool?
    public var id: String { label + "\u{0}" + rootPath }

    public init(label: String, rootPath: String, keepRootPath: Bool? = nil) {
        self.label = label
        self.rootPath = rootPath
        self.keepRootPath = keepRootPath
    }
}

public struct IndexRequest: Codable, Hashable, Sendable {
    public var db: String?
    public var disk: String
    public var description: String?
    public var mountPath: String
    public var collections: [CollectionSpec]?
    /// Replaces the disk's saved excludes; nil reuses them, [] clears them.
    public var excludes: [String]?
    public var noDefaultExcludes: Bool?
    public var force: Bool?

    public init(disk: String, mountPath: String, description: String? = nil,
                collections: [CollectionSpec]? = nil, excludes: [String]? = nil,
                noDefaultExcludes: Bool? = nil, force: Bool? = nil) {
        self.disk = disk
        self.mountPath = mountPath
        self.description = description
        self.collections = collections
        self.excludes = excludes
        self.noDefaultExcludes = noDefaultExcludes
        self.force = force
    }
}

public struct Progress: Codable, Hashable, Sendable {
    public var phase: String
    public var collection: String?
    public var added: Int
    public var updated: Int
    public var skipped: Int
    public var total: Int
    /// Paths that couldn't be read so far. Optional: older servers omit it.
    public var errors: Int?
    /// Files being removed during the "deleting" phase.
    public var deleting: Int?
    public var dirsTotal: Int
    public var dirsDone: Int
}

/// A file or folder the indexer couldn't read; what was indexed under it
/// before is kept.
public struct PathError: Codable, Hashable, Sendable {
    public var path: String
    public var error: String
}

public struct JobStats: Codable, Hashable, Sendable {
    public var added: Int
    public var updated: Int
    public var deleted: Int
    public var skipped: Int
    public var elapsedMs: Double
    public var errorCount: Int?
    public var errors: [PathError]?
    /// What this run skipped: the server defaults plus the disk's own.
    public var excludes: [String]?
}

public enum JobState: String, Codable, Sendable {
    case running, done, failed, cancelled
    /// Client-side only: the app lost track of a running job, e.g. because
    /// the server restarted (which stops it). Never sent by the server.
    case interrupted
}

public struct Job: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var state: JobState
    public var request: IndexRequest
    public var startedAt: Date
    public var finishedAt: Date?
    public var progress: Progress
    public var stats: JobStats?
    public var error: String?
    /// The schedule that started this run, if any.
    public var schedule: Int64?
}

/// A periodic reindex of a disk or one of its collections, run by the server.
public struct Schedule: Codable, Hashable, Sendable, Identifiable {
    public var db: String
    public var scheduleID: Int64
    public var disk: String
    /// nil (or empty) for the whole disk.
    public var collection: String?
    /// The disk's mount path, or the folder a collection is read from (nil =
    /// its saved location).
    public var path: String?
    public var intervalHours: Int
    /// "HH:MM" in the server's time zone.
    public var at: String?
    public var enabled: Bool
    public var mountPoint: String?
    public var createdAt: Date
    public var lastRunAt: Date?
    /// running, done, failed, cancelled, skipped or interrupted.
    public var lastStatus: String?
    public var lastMessage: String?
    public var lastJobId: String?
    public var nextRunAt: Date?

    /// IDs are only unique within one index, so qualify with the DB.
    public var id: String { "\(db)#\(scheduleID)" }

    enum CodingKeys: String, CodingKey {
        case db, scheduleID = "id", disk, collection, path, intervalHours, at, enabled, mountPoint,
             createdAt, lastRunAt, lastStatus, lastMessage, lastJobId, nextRunAt
    }

    public var isCollection: Bool { !(collection ?? "").isEmpty }
}

public struct ScheduleRequest: Codable, Hashable, Sendable {
    public var db: String?
    public var disk: String
    public var collection: String?
    public var path: String?
    public var intervalHours: Int
    public var at: String?
    public var enabled: Bool

    public init(db: String? = nil, disk: String, collection: String? = nil, path: String? = nil,
                intervalHours: Int, at: String? = nil, enabled: Bool = true) {
        self.db = db
        self.disk = disk
        self.collection = collection
        self.path = path
        self.intervalHours = intervalHours
        self.at = at
        self.enabled = enabled
    }
}

public struct DirEntry: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var id: String { path }
}

public struct DirListing: Codable, Sendable {
    public var path: String
    public var parent: String?
    public var entries: [DirEntry]
}

struct ErrorBody: Codable {
    var error: String
}
