import Foundation

/// Where a connected diskindexer server can be reached.
public struct Endpoint: Sendable {
    public var baseURL: URL
    public var token: String?

    public init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }
}

/// A way of reaching a server: a local child process, an SSH tunnel, ...
/// Platforms provide implementations; the Kit only sees the resulting Endpoint.
public protocol Transport: AnyObject {
    /// Shown in the UI, e.g. "This Mac" or "enterprise".
    var displayName: String { get }
    /// True when the server shares this device's filesystem, so a native
    /// folder picker can be used instead of the remote directory browser.
    var isLocal: Bool { get }
    /// Called (on any thread) if the connection dies after connect() returned.
    var onDisconnect: (@Sendable (String) -> Void)? { get set }
    func connect() async throws -> Endpoint
    func disconnect()
    /// The address in use when a server has several (e.g. LAN, then
    /// Tailscale), for showing in the UI. nil when there's only one way in.
    var activeAddress: String? { get }
}

public extension Transport {
    var activeAddress: String? { nil }
}

public struct APIError: LocalizedError, Sendable {
    public var status: Int
    public var message: String
    public var errorDescription: String? { message }
}

public final class APIClient: Sendable {
    public let endpoint: Endpoint
    private let session: URLSession
    private let eventsSession: URLSession

    /// `latency` is the measured round-trip time; a slow link gets longer
    /// timeouts, so requests aren't abandoned just because the link is slow.
    public init(endpoint: Endpoint, latency: TimeInterval = 0) {
        self.endpoint = endpoint
        // Ordinary requests: a dead server or tunnel should surface quickly.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout(latency: latency)
        config.httpMaximumConnectionsPerHost = Self.maxConnections
        session = URLSession(configuration: config)
        // Progress streams stay open for the whole run and can go quiet during
        // long phases; if one idles out, AppModel re-attaches.
        let events = URLSessionConfiguration.ephemeral
        events.timeoutIntervalForRequest = 120 + 20 * latency
        events.timeoutIntervalForResource = 7 * 24 * 3600
        events.httpMaximumConnectionsPerHost = Self.maxStreams
        eventsSession = URLSession(configuration: events)
    }

    /// Over SSH on iOS each HTTP connection holds an SSH session, and OpenSSH
    /// allows 10 per login (MaxSessions); an on-demand server takes one more.
    static let maxConnections = 4
    static let maxStreams = 3

    deinit {
        // Close idle connections now rather than when they time out: AppModel
        // replaces its client on every connect, and over SSH each open
        // connection holds a session.
        session.finishTasksAndInvalidate()
        eventsSession.finishTasksAndInvalidate()
    }

    // MARK: Endpoints

    public func info() async throws -> ServerInfo {
        try await send("GET", "v1/info")
    }

    /// info() with its own timeout, to check quickly that the server answers.
    public func ping(timeout: TimeInterval) async throws {
        var req = request("GET", "v1/info")
        req.timeoutInterval = timeout
        let (data, response) = try await session.data(for: req)
        try check(response, data: data)
    }

    /// 15s, plus 20 round trips on a slow link.
    static func requestTimeout(latency: TimeInterval) -> TimeInterval {
        15 + 20 * latency
    }

    public func disks() async throws -> [Disk] {
        try await send("GET", "v1/disks")
    }

    public func collections() async throws -> [Collection] {
        try await send("GET", "v1/collections")
    }

    public func search(_ req: SearchRequest) async throws -> SearchResponse {
        try await send("POST", "v1/search", body: req)
    }

    public func renameCollection(_ c: Collection, to label: String) async throws {
        struct Body: Encodable { var db: String; var label: String }
        try await sendNoContent("PATCH", "v1/collections/\(c.id)", body: Body(db: c.db, label: label))
    }

    public func moveCollection(_ c: Collection, toDisk disk: String) async throws -> Collection {
        struct Body: Encodable { var db: String; var disk: String }
        return try await send("POST", "v1/collections/\(c.id)/move", body: Body(db: c.db, disk: disk))
    }

    public func deleteCollection(_ c: Collection) async throws {
        try await sendNoContent("DELETE", "v1/collections/\(c.id)", query: ["db": c.db])
    }

    public func deleteDisk(_ d: Disk) async throws {
        try await sendNoContent("DELETE", "v1/disks/\(d.label)", query: ["db": d.db])
    }

    public func jobs() async throws -> [Job] {
        try await send("GET", "v1/jobs")
    }

    public func startIndex(_ req: IndexRequest) async throws -> Job {
        try await send("POST", "v1/jobs", body: req)
    }

    public func job(_ id: String) async throws -> Job {
        try await send("GET", "v1/jobs/\(id)")
    }

    public func cancelJob(_ id: String) async throws -> Job {
        try await send("DELETE", "v1/jobs/\(id)")
    }

    public func schedules() async throws -> [Schedule] {
        try await send("GET", "v1/schedules")
    }

    /// Creates a schedule (id nil) or replaces one's settings.
    public func saveSchedule(_ req: ScheduleRequest, id: Int64? = nil) async throws -> Schedule {
        if let id {
            return try await send("PUT", "v1/schedules/\(id)", body: req)
        }
        return try await send("POST", "v1/schedules", body: req)
    }

    public func deleteSchedule(_ s: Schedule) async throws {
        try await sendNoContent("DELETE", "v1/schedules/\(s.scheduleID)", query: ["db": s.db])
    }

    /// Runs a schedule now; the result says whether it started or was skipped.
    public func runSchedule(_ s: Schedule) async throws -> Schedule {
        try await send("POST", "v1/schedules/\(s.scheduleID)/run", query: ["db": s.db])
    }

    public func fsRoots() async throws -> [DirEntry] {
        try await send("GET", "v1/fs/roots")
    }

    public func listDir(_ path: String) async throws -> DirListing {
        try await send("GET", "v1/fs/list", query: ["path": path])
    }

    /// Streams job snapshots from the server-sent events endpoint until the
    /// job finishes (the last element has a non-running state).
    public func jobEvents(_ id: String) -> AsyncThrowingStream<Job, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await eventsSession.bytes(for: request("GET", "v1/jobs/\(id)/events"))
                    try check(response, data: nil)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let job = try Self.decoder.decode(Job.self, from: Data(line.dropFirst(6).utf8))
                        continuation.yield(job)
                        if job.state != .running { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Plumbing

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Go emits RFC 3339 with optional fractional seconds.
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = parseRFC3339(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private func request(_ method: String, _ path: String, query: [String: String] = [:]) -> URLRequest {
        var comps = URLComponents(url: endpoint.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let token = endpoint.token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func check(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = data.flatMap { try? Self.decoder.decode(ErrorBody.self, from: $0).error }
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIError(status: http.statusCode, message: message)
        }
    }

    private func perform(_ method: String, _ path: String, query: [String: String], body: (any Encodable)?) async throws -> Data {
        var req = request(method, path, query: query)
        if let body {
            req.httpBody = try Self.encoder.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        try check(response, data: data)
        return data
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:], body: (any Encodable)? = nil) async throws -> T {
        let data = try await perform(method, path, query: query, body: body)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func sendNoContent(_ method: String, _ path: String, query: [String: String] = [:], body: (any Encodable)? = nil) async throws {
        _ = try await perform(method, path, query: query, body: body)
    }
}

func parseRFC3339(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}
