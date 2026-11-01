import Foundation

/// A failure to reach a server, saying whether trying again later could help.
/// Transports throw it from connect(); AppModel keeps retrying transient ones
/// ("Waiting for …") and stops on the rest.
public struct ConnectionFailure: LocalizedError, Sendable {
    public var message: String
    public var isTransient: Bool

    public init(_ message: String, isTransient: Bool) {
        self.message = message
        self.isTransient = isTransient
    }

    public var errorDescription: String? { message }
}

/// What kind of problem an ssh error message describes.
public enum SSHFailureKind: Equatable, Sendable {
    /// Can't reach the host: DNS, timeout, refused, network down (e.g.
    /// Tailscale not connected). Worth retrying.
    case network
    /// The host is reachable but its key isn't trusted. Needs the user.
    case hostKey
    /// The host rejected our credentials. Needs the user.
    case auth
    /// Anything else. Retried, showing ssh's own message, so a real problem
    /// stays visible instead of looking like a slow network.
    case other

    public var isTransient: Bool { self == .network || self == .other }

    /// Classifies ssh's stderr. Host-key and auth checks come first because
    /// their messages can also mention the connection being closed.
    public static func classify(_ stderr: String) -> SSHFailureKind {
        let s = stderr.lowercased()
        let hostKey = [
            "host key verification failed",
            "remote host identification has changed",
            "no matching host key",
            "host key for",
        ]
        let auth = [
            "permission denied",
            "too many authentication failures",
            "no supported authentication methods",
        ]
        let network = [
            "could not resolve hostname",
            "nodename nor servname",
            "name or service not known",
            "temporary failure in name resolution",
            "operation timed out",
            "connection timed out",
            "no route to host",
            "network is unreachable",
            "network is down",
            "connection refused",
            "connection reset",
            "connection closed",
            "broken pipe",
            "kex_exchange_identification",
            "timeout, server",
        ]
        if hostKey.contains(where: s.contains) { return .hostKey }
        if auth.contains(where: s.contains) { return .auth }
        if network.contains(where: s.contains) { return .network }
        return .other
    }
}

extension Error {
    /// Whether retrying a failed connect could succeed. Network errors from
    /// URLSession are transient; anything not marked otherwise is not.
    var isTransientConnectionError: Bool {
        if let f = self as? ConnectionFailure { return f.isTransient }
        if let u = self as? URLError {
            switch u.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                 .cannotFindHost, .dnsLookupFailed, .badServerResponse:
                return true
            default:
                return false
            }
        }
        return false
    }
}
