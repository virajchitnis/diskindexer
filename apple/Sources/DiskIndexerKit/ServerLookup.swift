import Foundation

/// Finding diskindexer on a server over SSH, shared by the Mac's ssh tunnel
/// and the iOS transport: a script run with `sh -c` reports the socket of a
/// running server, or the binary to start one with, or that nothing is
/// installed.
public enum ServerLookup {
    public static let defaultSocket = "~/.config/diskindexer/server.sock"

    /// What the lookup found.
    public struct Found: Equatable, Sendable {
        /// Absolute path of the server's socket.
        public var socket: String
        /// The diskindexer binary on the server, when the script found one.
        public var binary: String?
        /// True when no server is running: start `binary serve --stdin-watch`
        /// for the connection ("on demand").
        public var onDemand: Bool

        public init(socket: String, binary: String?, onDemand: Bool) {
            self.socket = socket
            self.binary = binary
            self.onDemand = onDemand
        }
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The command to run over SSH, through sh so it works whatever the
    /// login shell. nil socketPath (or empty) means the default socket.
    public static func command(socketPath: String?) throws -> String {
        let path = socketPath?.trimmingCharacters(in: .whitespaces) ?? ""
        let socket = path.isEmpty ? defaultSocket : path
        guard !socket.contains("'"), !socket.contains("\"") else {
            throw ConnectionFailure("The socket path can\u{2019}t contain quotes.", isTransient: false)
        }
        return "sh -c " + shellQuote(script(socketPath: socket))
    }

    /// When a systemd service is installed, the script waits a few seconds
    /// for the socket: without linger, the service only starts with this
    /// login. Prints "socket", "ondemand" or "missing" (exit 3) on the first
    /// line, then the socket path, then the binary if known.
    public static func script(socketPath: String) -> String {
        let shellPath = socketPath.hasPrefix("~/") ? "$HOME/" + socketPath.dropFirst(2) : socketPath
        return """
            p="\(shellPath)"
            bin="$HOME/.local/bin/diskindexer"
            [ -x "$bin" ] || bin=$(command -v diskindexer 2>/dev/null || true)
            if systemctl --user cat diskindexer >/dev/null 2>&1; then
              i=0; while [ ! -S "$p" ] && [ $i -lt 20 ]; do sleep 0.25; i=$((i+1)); done
            fi
            if [ -S "$p" ]; then printf 'socket\\n%s\\n%s\\n' "$p" "$bin"; exit 0; fi
            if [ -n "$bin" ]; then printf 'ondemand\\n%s\\n%s\\n' "$p" "$bin"; exit 0; fi
            printf 'missing\\n%s\\n' "$p"; exit 3
            """
    }

    /// Reads the script's output. Goes by what it printed rather than its
    /// exit status, which some SSH libraries don't always report.
    public static func parse(_ stdout: String, stderr: String, serverName: String) throws -> Found {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let binary = lines.count >= 3 && !lines[2].isEmpty ? lines[2] : nil
        switch lines.first {
        case "socket" where lines.count >= 2:
            return Found(socket: lines[1], binary: binary, onDemand: false)
        case "ondemand" where lines.count >= 3 && binary != nil:
            return Found(socket: lines[1], binary: binary, onDemand: true)
        case "missing":
            // Nothing installed: the app offers to set it up.
            throw ConnectionFailure("""
                diskindexer isn't installed on \(serverName).
                Set it up from here, or install it there yourself (see the README).
                """, isTransient: true, reason: .notRunning)
        default:
            let detail = stderr.isEmpty ? stdout : stderr
            throw ConnectionFailure("Checking diskindexer on \(serverName) failed: \(detail)", isTransient: true)
        }
    }

    /// The command that starts a server for one connection; it exits when
    /// its stdin (the SSH session) closes. With idleExit, also after that
    /// many seconds without requests or a running index job, which needs a
    /// diskindexer with `serve --idle-exit`: sshd keeps the server running
    /// when a connection just drops.
    public static func onDemandCommand(_ found: Found, idleExit: Int? = nil) -> String {
        let idle = idleExit.map { " --idle-exit \($0)s" } ?? ""
        return "\(shellQuote(found.binary ?? "diskindexer")) serve --stdin-watch\(idle) --listen \(shellQuote("unix:" + found.socket))"
    }
}
