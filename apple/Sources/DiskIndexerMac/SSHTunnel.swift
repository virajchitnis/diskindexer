import DiskIndexerKit
import Foundation

/// Reaches `diskindexer serve` on a remote host by forwarding a local loopback
/// port to the server's Unix socket with the system ssh. Authentication,
/// host keys and host aliases all come from ~/.ssh/config and ssh-agent.
final class SSHTunnel: Transport {
    let host: String
    /// Remote socket path; nil means the server default. A leading "~/" is
    /// resolved against the remote $HOME.
    let socketPath: String?
    let displayName: String
    let isLocal = false
    var onDisconnect: (@Sendable (String) -> Void)?

    private var process: Process?
    /// Write end of the wrapper's stdin; closing it stops ssh (see diesWithParent).
    private var lifeline: Pipe?
    private let stopping = AtomicFlag()

    static let ssh = "/usr/bin/ssh"
    static let defaultSocket = "~/.config/diskindexer/server.sock"

    init(name: String, host: String, socketPath: String?) {
        self.displayName = name
        self.host = host
        self.socketPath = socketPath
    }

    /// Options shared by every ssh invocation. BatchMode makes ssh fail rather
    /// than prompt, since there's no terminal; ControlPath=none keeps a
    /// multiplexed master connection from swallowing our forward.
    private var commonOptions: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ControlPath=none"]
    }

    func connect() async throws -> Endpoint {
        stopping.set(false)
        let socket = try await resolveSocket()
        let port = try freeLoopbackPort()

        // Run ssh through a wrapper so the tunnel can't outlive the app.
        let cmd = diesWithParent(Self.ssh, commonOptions + [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(port):\(socket)",
            host,
        ])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.executable)
        p.arguments = cmd.arguments
        let lifeline = Pipe()
        p.standardInput = lifeline
        p.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        p.standardError = stderr
        let errBuf = OutputBuffer(stderr)
        let name = displayName
        p.terminationHandler = { [weak self] _ in
            guard let self, !self.stopping.isSet else { return }
            let detail = errBuf.text
            self.onDisconnect?(detail.isEmpty ? "SSH connection to \(name) closed." : detail)
        }
        try p.run()
        process = p
        self.lifeline = lifeline

        // Wait for the forward to answer.
        let endpoint = Endpoint(baseURL: URL(string: "http://127.0.0.1:\(port)/")!)
        let client = APIClient(endpoint: endpoint)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !p.isRunning {
                process = nil
                throw ProcessFailure(message: "SSH to \(host) failed: \(errBuf.text)")
            }
            if (try? await client.info()) != nil {
                return endpoint
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        disconnect()
        throw ProcessFailure(message: "Timed out waiting for diskindexer on \(host).")
    }

    /// Logs in once to turn the socket path into an absolute one and to check
    /// the server is running, so failures come with a useful message.
    private func resolveSocket() async throws -> String {
        let path = socketPath?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? Self.defaultSocket
        guard !path.contains("'") else {
            throw ProcessFailure(message: "The socket path can't contain a single quote.")
        }
        let shellPath = path.hasPrefix("~/") ? "$HOME/" + path.dropFirst(2) : path
        // Run through sh explicitly so it works whatever the login shell is.
        let script = #"p="\#(shellPath)"; if [ -S "$p" ]; then printf '%s\n' "$p"; else printf 'missing %s\n' "$p"; exit 3; fi"#
        let command = "sh -c '" + script.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let r = try await runCommand(Self.ssh, commonOptions + [host, command])
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        switch r.status {
        case 0 where out.hasPrefix("/"):
            return out
        case 3:
            let missing = out.replacingOccurrences(of: "missing ", with: "")
            throw ProcessFailure(message: """
                diskindexer isn't running on \(host): no socket at \(missing).
                Start it there with `systemctl --user start diskindexer` (set up with `make install-service`), or run `diskindexer serve`.
                """)
        case 255:
            throw ProcessFailure(message: """
                Couldn't SSH to \(host): \(r.stderr)
                The app uses your ~/.ssh/config and ssh-agent and can't answer prompts. Run `ssh \(host)` in Terminal once to accept the host key and make sure your key is loaded.
                """)
        default:
            throw ProcessFailure(message: "Checking diskindexer on \(host) failed: \(r.stderr.isEmpty ? out : r.stderr)")
        }
    }

    func disconnect() {
        stopping.set(true)
        // EOF on the lifeline makes the wrapper kill ssh; terminating the
        // wrapper alone would leave ssh running.
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
        process = nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
