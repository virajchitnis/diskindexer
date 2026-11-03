import Foundation

/// A transport that can install or update diskindexer on its server (the SSH
/// transport). AppModel offers Install/Update when the transport conforms.
public protocol ServerManaging: AnyObject {
    /// The version this app would install, e.g. "1.3.2". nil if unknown.
    var bundledVersion: String? { get }
    /// Copies the bundled binary to the server, sets up and (re)starts its
    /// service, and reports what it did. `progress` gets one line per step.
    func installServer(progress: @escaping @Sendable (String) -> Void) async throws -> InstallReport
}

public struct InstallReport: Sendable, Equatable {
    /// The version the server now runs.
    public var version: String
    /// No service was set up (no systemd): the app starts the server for
    /// each connection, so it only runs while the app is connected.
    public var onDemand: Bool
    /// Whether the service keeps running (and finishes index runs) while
    /// nobody is logged in. Optional: when false, `lingerCommand` turns it on.
    public var lingerEnabled: Bool
    public var lingerCommand: String?

    public init(version: String, onDemand: Bool = false, lingerEnabled: Bool, lingerCommand: String?) {
        self.version = version
        self.onDemand = onDemand
        self.lingerEnabled = lingerEnabled
        self.lingerCommand = lingerCommand
    }
}

/// What happens to an index run if the app goes away, for the Index sheet.
/// nil when the server keeps running (or it's unknown), so there's nothing
/// to warn about.
public func backgroundRunNote(info: ServerInfo?, serverName: String, isLocal: Bool) -> String? {
    guard let info, info.persistent == false else { return nil }
    if isLocal {
        return "Indexing runs while this app is open; quitting it stops the run. Files indexed so far are kept."
    }
    var note = "\(serverName) only runs diskindexer while this app is connected, so the run stops if your Mac disconnects or sleeps. Files indexed so far are kept."
    if info.os == "linux" {
        note += " To let runs finish on their own, run `sudo loginctl enable-linger \(info.user ?? "$USER")` on \(serverName) once."
    }
    return note
}

/// A diskindexer version from `git describe`, e.g. "v1.3.1-20-gabc123-dirty":
/// 1.3.1 plus 20 commits. Development builds without a tag don't parse.
public struct ServerVersion: Comparable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public var commits: Int

    public init?(_ s: String) {
        let parts = s.trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "v" })
            .split(separator: "-")
        guard let first = parts.first else { return nil }
        let nums = first.split(separator: ".").compactMap { Int($0) }
        guard nums.count == 3 else { return nil }
        (major, minor, patch) = (nums[0], nums[1], nums[2])
        // "-20-gabc123": commits since the tag.
        if parts.count >= 3, let n = Int(parts[1]), parts[2].hasPrefix("g") {
            commits = n
        } else {
            commits = 0
        }
    }

    public static func < (a: ServerVersion, b: ServerVersion) -> Bool {
        (a.major, a.minor, a.patch, a.commits) < (b.major, b.minor, b.patch, b.commits)
    }

    public var description: String {
        commits == 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor).\(patch)+\(commits)"
    }
}

/// Tries `attempt` against each address in order and returns the first that
/// works. Only an unreachable address (ConnectionFailure.Reason.unreachable)
/// moves on to the next: any other failure means the server answered, so the
/// same problem would follow on every address and is reported straight away.
/// If none is reachable, the error lists what each address said.
public func firstReachable<T>(
    _ addresses: [String],
    attempt: (_ address: String, _ isLast: Bool) async throws -> T
) async throws -> (address: String, value: T) {
    var failures: [String] = []
    for (i, address) in addresses.enumerated() {
        do {
            return (address, try await attempt(address, i == addresses.count - 1))
        } catch let f as ConnectionFailure where f.reason == .unreachable {
            failures.append(addresses.count > 1 ? "\(address): \(f.message)" : f.message)
        }
    }
    guard !failures.isEmpty else {
        throw ConnectionFailure("No address to connect to.", isTransient: false)
    }
    throw ConnectionFailure(failures.joined(separator: "\n"), isTransient: true, reason: .unreachable)
}

/// When the server's schedules run, for the Schedules view and editor.
public func scheduleRunNote(info: ServerInfo?, serverName: String) -> String {
    guard let info else { return "" }
    if info.scheduler != true {
        return "\(serverName) only runs diskindexer while this app is connected, so schedules don\u{2019}t run there."
    }
    switch info.persistent {
    case true:
        return "Schedules run on \(serverName) around the clock, whether or not this app is connected."
    case false:
        var note = "\(serverName) stops diskindexer when you log out, so schedules only run while you\u{2019}re logged in there or this app is connected."
        if info.os == "linux" {
            note += " To run them around the clock, run `sudo loginctl enable-linger \(info.user ?? "$USER")` on \(serverName) once."
        }
        return note
    default:
        return "Schedules run while diskindexer is running on \(serverName)."
    }
}
