import DiskIndexerKit
import Foundation
import os

/// Reaches `diskindexer serve` on a remote host by forwarding a local loopback
/// port to the server's Unix socket with the system ssh. Authentication,
/// host keys and host aliases all come from ~/.ssh/config and ssh-agent.
///
/// A server can have several addresses (e.g. its LAN IP, then its Tailscale
/// name); each connect tries them in order and uses the first that answers.
/// It also installs and updates diskindexer on Linux servers with systemd.
final class SSHTunnel: Transport, ServerManaging {
    let hosts: [String]
    /// Remote socket path; nil means the server default. A leading "~/" is
    /// resolved against the remote $HOME.
    let socketPath: String?
    let displayName: String
    let isLocal = false
    var onDisconnect: (@Sendable (String) -> Void)?
    /// The address the current connection uses.
    private(set) var activeAddress: String?

    /// The master ssh connection (through its diesWithParent wrapper).
    private var process: Process?
    /// Write end of the wrapper's stdin; closing it stops ssh (see diesWithParent).
    private var lifeline: Pipe?
    private var masterErrors: OutputBuffer?
    /// Holds the master's control socket.
    private var controlDir: String?
    /// An on-demand server's session, and the pipe that is its stdin.
    private var session: Process?
    private var sessionInput: Pipe?
    private let stopping = AtomicFlag()

    static let ssh = "/usr/bin/ssh"
    static let defaultSocket = "~/.config/diskindexer/server.sock"

    init(name: String, hosts: [String], socketPath: String?) {
        self.displayName = name
        self.hosts = hosts
        self.socketPath = socketPath
    }

    /// Options shared by every ssh invocation. BatchMode makes ssh fail rather
    /// than prompt, since there's no terminal; ControlPath=none keeps a
    /// multiplexed master connection from swallowing our forward. Addresses
    /// that aren't the last get a short timeout, so an unreachable LAN
    /// address fails over quickly.
    func sshOptions(timeout: Int = 10) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)", "-o", "ControlPath=none"]
    }

    func connect() async throws -> Endpoint {
        stopping.set(false)
        let started = Date()
        // One SSH login per connect: a master connection the app owns, which
        // the server lookup and the port forward then share. On a slow link
        // each extra login costs several round trips.
        let (host, mux) = try await firstReachable(hosts) { host, isLast in
            try await startMaster(on: host, timeout: isLast ? 10 : 4)
        }
        activeAddress = host
        Log.connect.notice("ssh login to \(host, privacy: .public): \(Date().timeIntervalSince(started), format: .fixed(precision: 3))s")
        do {
            return try await attach(host: host, mux: mux)
        } catch {
            disconnect()
            throw error
        }
    }

    /// Finds the server over the master connection, starts one if needed,
    /// and forwards a local port to its socket.
    private func attach(host: String, mux: [String]) async throws -> Endpoint {
        var t = Date()
        let server = try await findServer(on: host, mux: mux)
        Log.connect.notice("found server: \(Date().timeIntervalSince(t), format: .fixed(precision: 3))s")
        if let binary = server.onDemandBinary {
            // No running server: start one for this connection. Its stdin is
            // a pipe the app holds, so when the app disconnects or dies, the
            // session ends and `serve --stdin-watch` exits.
            let remote = "\(Self.shellQuote(binary)) serve --stdin-watch --listen \(Self.shellQuote("unix:" + server.socket))"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Self.ssh)
            p.arguments = mux + [host, remote]
            let input = Pipe()
            p.standardInput = input
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            watchExit(of: p, stderr: nil)
            try p.run()
            session = p
            sessionInput = input
        }

        t = Date()
        let port = try freeLoopbackPort()
        let fwd = try await runCommand(Self.ssh, mux + ["-O", "forward", "-L", "127.0.0.1:\(port):\(server.socket)", host])
        guard fwd.status == 0 else {
            throw ConnectionFailure("Couldn\u{2019}t forward a port to diskindexer on \(host): \(fwd.stderr)", isTransient: true)
        }

        // Wait for the forward to answer.
        let endpoint = Endpoint(baseURL: URL(string: "http://127.0.0.1:\(port)/")!)
        let client = APIClient(endpoint: endpoint)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if process?.isRunning != true {
                throw sshFailure(masterErrors?.text ?? "", host: host)
            }
            if (try? await client.info()) != nil {
                Log.connect.notice("forward answering: \(Date().timeIntervalSince(t), format: .fixed(precision: 3))s")
                return endpoint
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // Usually the service restarting, or a socket left by a crash.
        throw ConnectionFailure("Timed out waiting for diskindexer on \(host).", isTransient: true)
    }

    /// Logs in to `host` as a master connection with its own control socket,
    /// and returns the ssh options that run commands over it. Fails like a
    /// normal login (network, host key, auth) if the login does.
    private func startMaster(on host: String, timeout: Int) async throws -> [String] {
        // Control sockets have a short path limit, so not NSTemporaryDirectory.
        var template = Array("/tmp/diskindexer.XXXXXX".utf8CString)
        guard let dir = mkdtemp(&template).map({ String(cString: $0) }) else {
            throw ProcessFailure(message: "Couldn\u{2019}t create a folder for the SSH connection.")
        }
        let control = dir + "/c"
        controlDir = dir
        let master = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)",
            "-o", "ControlMaster=yes", "-o", "ControlPath=\(control)", "-o", "ControlPersist=no",
            // Notice a dead link in ~30s. A change of network is noticed
            // sooner: the app checks the connection when that happens.
            "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=6",
            "-N", host,
        ]
        // Run ssh through a wrapper so the master (and with it every session
        // and forward) can't outlive the app.
        let cmd = diesWithParent(Self.ssh, master)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd.executable)
        p.arguments = cmd.arguments
        let lifeline = Pipe()
        p.standardInput = lifeline
        p.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        p.standardError = stderr
        let errors = OutputBuffer(stderr)
        let ready = AtomicFlag()
        p.terminationHandler = { [weak self] proc in
            // A master from an earlier connection ending late isn't news.
            guard let self, ready.isSet, !self.stopping.isSet, self.process === proc else { return }
            let detail = errors.text
            self.onDisconnect?(detail.isEmpty ? "SSH connection to \(self.displayName) closed." : detail)
        }
        try p.run()
        process = p
        self.lifeline = lifeline
        masterErrors = errors

        // The control socket appears once the login has succeeded.
        let deadline = Date().addingTimeInterval(Double(timeout) + 20)
        while !FileManager.default.fileExists(atPath: control) {
            if !p.isRunning {
                p.waitUntilExit()
                let stderrText = errors.text
                cleanUp()
                if SSHFailureKind.classify(stderrText) == .hostKey {
                    throw await hostKeyFailure(host: host, stderr: stderrText)
                }
                throw sshFailure(stderrText, host: host)
            }
            if Date() > deadline {
                disconnect()
                throw ConnectionFailure("Timed out logging in to \(host).", isTransient: true, reason: .unreachable)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        ready.set(true)
        return ["-o", "ControlPath=\(control)", "-o", "ControlMaster=no", "-o", "BatchMode=yes"]
    }

    /// Reports the end of a process the connection depends on as a disconnect.
    private func watchExit(of p: Process, stderr: OutputBuffer?) {
        let name = displayName
        p.terminationHandler = { [weak self] proc in
            guard let self, !self.stopping.isSet, self.session === proc else { return }
            let detail = stderr?.text ?? ""
            self.onDisconnect?(detail.isEmpty ? "The diskindexer session on \(name) ended." : detail)
        }
    }

    /// Turns ssh's stderr into a failure with advice that fits the cause.
    /// Network-type failures are `.unreachable`, so the next address is tried.
    private func sshFailure(_ stderr: String, host: String) -> ConnectionFailure {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        switch SSHFailureKind.classify(detail) {
        case .network:
            return ConnectionFailure("Can\u{2019}t reach \(host): \(detail)\nCheck that the server is on and the network (or Tailscale) is connected.",
                                     isTransient: true, reason: .unreachable)
        case .hostKey:
            return ConnectionFailure("""
                \(host)\u{2019}s host key isn\u{2019}t trusted: \(detail)
                Run `ssh \(host)` in Terminal to check and accept it; the app can\u{2019}t answer that prompt.
                """, isTransient: false)
        case .auth:
            return ConnectionFailure("""
                \(host) refused the login: \(detail)
                The app uses your ~/.ssh/config and ssh-agent and can\u{2019}t type a password. Make sure \u{201C}ssh \(host)\u{201D} works in Terminal without prompting.
                """, isTransient: false)
        case .other:
            return ConnectionFailure("SSH to \(host) failed: \(detail.isEmpty ? "ssh exited" : detail)",
                                     isTransient: true, reason: .unreachable)
        }
    }

    /// Where to connect: an existing server's socket, or, when nothing is
    /// listening but diskindexer is installed, a socket to start one on for
    /// this connection.
    private struct FoundServer {
        var socket: String
        var onDemandBinary: String?
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Script run on the server (with `sh -c`) to find what to connect to.
    /// When a systemd service is installed, it waits a few seconds for the
    /// socket: without linger, the service only starts with this login.
    static func findServerScript(socketPath: String) -> String {
        let shellPath = socketPath.hasPrefix("~/") ? "$HOME/" + socketPath.dropFirst(2) : socketPath
        return """
            p="\(shellPath)"
            if systemctl --user cat diskindexer >/dev/null 2>&1; then
              i=0; while [ ! -S "$p" ] && [ $i -lt 20 ]; do sleep 0.25; i=$((i+1)); done
            fi
            if [ -S "$p" ]; then printf 'socket\n%s\n' "$p"; exit 0; fi
            bin="$HOME/.local/bin/diskindexer"
            [ -x "$bin" ] || bin=$(command -v diskindexer 2>/dev/null || true)
            if [ -n "$bin" ]; then printf 'ondemand\n%s\n%s\n' "$p" "$bin"; exit 0; fi
            printf 'missing\n%s\n' "$p"; exit 3
            """
    }

    /// Finds the server's socket (as an absolute path) or how to start one,
    /// over the master connection, so failures come with a useful message.
    private func findServer(on host: String, mux: [String]) async throws -> FoundServer {
        let path = socketPath?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? Self.defaultSocket
        guard !path.contains("'"), !path.contains("\"") else {
            throw ProcessFailure(message: "The socket path can't contain quotes.")
        }
        // Run through sh explicitly so it works whatever the login shell is.
        let command = "sh -c " + Self.shellQuote(Self.findServerScript(socketPath: path))
        let r = try await runCommand(Self.ssh, mux + [host, command])
        let lines = r.stdout.split(separator: "\n").map(String.init)
        switch r.status {
        case 0 where lines.first == "socket" && lines.count >= 2:
            return FoundServer(socket: lines[1])
        case 0 where lines.first == "ondemand" && lines.count >= 3:
            return FoundServer(socket: lines[1], onDemandBinary: lines[2])
        case 3:
            // Nothing installed: the app offers to set it up.
            throw ConnectionFailure("""
                diskindexer isn't installed on \(displayName).
                Set it up from here, or install it there yourself (see the README).
                """, isTransient: true, reason: .notRunning)
        case 255:
            throw sshFailure(r.stderr, host: host)
        default:
            throw ConnectionFailure("Checking diskindexer on \(host) failed: \(r.stderr.isEmpty ? r.stdout : r.stderr)", isTransient: true)
        }
    }

    func disconnect() {
        stopping.set(true)
        cleanUp()
    }

    private func cleanUp() {
        // EOF on the lifeline makes the wrapper kill the master ssh, which
        // ends the session and forward too; terminating the wrapper alone
        // would leave ssh running.
        try? sessionInput?.fileHandleForWriting.close()
        sessionInput = nil
        session = nil
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
        process = nil
        masterErrors = nil
        if let dir = controlDir {
            try? FileManager.default.removeItem(atPath: dir)
            controlDir = nil
        }
    }

    // MARK: Installing and updating the server

    var bundledVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Uploads the matching bundled binary to ~/.local/bin/diskindexer (via a
    /// rename, so a running copy isn't disturbed). On Linux with systemd it
    /// also writes the user unit and (re)starts the service; lingering, which
    /// keeps it running after logout, is enabled if sudo works without a
    /// password and is otherwise optional (the report says how). Elsewhere
    /// (macOS, no systemd) there's no service: the app starts the server for
    /// each connection.
    func installServer(progress: @escaping @Sendable (String) -> Void) async throws -> InstallReport {
        progress("Connecting to \(displayName)\u{2026}")
        let (host, platform) = try await firstReachable(activeAddress.map { [$0] + hosts.filter { $0 != activeAddress } } ?? hosts) { host, isLast in
            try await preflight(on: host, timeout: isLast ? 10 : 4)
        }

        let binaryName: String
        switch (platform.os, platform.machine) {
        case ("Linux", "x86_64"), ("Linux", "amd64"): binaryName = "diskindexer-linux-amd64"
        case ("Linux", "aarch64"), ("Linux", "arm64"): binaryName = "diskindexer-linux-arm64"
        case ("Darwin", _): binaryName = "diskindexer" // universal
        default:
            throw ProcessFailure(message: "The app doesn\u{2019}t include diskindexer for \(platform.os) \(platform.machine).")
        }
        // Without systemd there's no service to set up: the app starts the
        // server for each connection instead (on demand).
        let useService = platform.os == "Linux" && platform.hasSystemd
        guard let binary = Bundle.main.url(forResource: binaryName, withExtension: nil) else {
            throw ProcessFailure(message: "This build of the app doesn\u{2019}t include the server files (build it with `make mac-app`).")
        }
        var unit = ""
        if useService {
            guard let unitURL = Bundle.main.url(forResource: "diskindexer", withExtension: "service"),
                  let text = try? String(contentsOf: unitURL, encoding: .utf8) else {
                throw ProcessFailure(message: "This build of the app doesn\u{2019}t include the service file (build it with `make mac-app`).")
            }
            unit = text
        }

        progress("Copying diskindexer to \(displayName) (\(platform.os) \(platform.machine))\u{2026}")
        let upload = "mkdir -p ~/.local/bin && cat > ~/.local/bin/diskindexer.new && chmod +x ~/.local/bin/diskindexer.new && mv ~/.local/bin/diskindexer.new ~/.local/bin/diskindexer"
        let up = try await runCommand(Self.ssh, sshOptions() + [host, upload], stdin: .file(binary))
        guard up.status == 0 else {
            throw ProcessFailure(message: "Copying diskindexer failed: \(up.stderr)")
        }

        guard useService else {
            let r = try await runCommand(Self.ssh, sshOptions() + [host, "~/.local/bin/diskindexer --version"])
            let version = r.stdout.split(separator: " ").dropFirst().first.map(String.init) ?? "unknown"
            progress("diskindexer \(version) is installed on \(displayName); the app starts it whenever it connects.")
            return InstallReport(version: version, onDemand: true, lingerEnabled: false, lingerCommand: nil)
        }

        progress("Setting up and starting the service\u{2026}")
        let r = try await runCommand(Self.ssh, sshOptions() + [host, "sh -s"], stdin: .text(Self.serviceScript(unit: unit)))
        let lines = r.stdout.split(separator: "\n").map(String.init)
        guard r.status == 0 else {
            throw ProcessFailure(message: "Starting the service failed:\n\((lines + [r.stderr]).joined(separator: "\n"))")
        }
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        let version = value("version")?.split(separator: " ").dropFirst().first.map(String.init) ?? "unknown"
        let linger = value("linger") == "yes"
        let user = value("user") ?? "$USER"
        progress("diskindexer \(version) is running on \(displayName).")
        return InstallReport(version: version, onDemand: false, lingerEnabled: linger,
                             lingerCommand: linger ? nil : "sudo loginctl enable-linger \(user)")
    }

    private struct Platform {
        var os: String
        var machine: String
        var hasSystemd: Bool
    }

    private func preflight(on host: String, timeout: Int) async throws -> Platform {
        let r = try await runCommand(Self.ssh, sshOptions(timeout: timeout) + [host,
            "uname -sm; command -v systemctl >/dev/null 2>&1 && echo systemd || echo none"])
        guard r.status == 0 else {
            throw r.status == 255 ? sshFailure(r.stderr, host: host)
                : ProcessFailure(message: "Couldn\u{2019}t inspect \(host): \(r.stderr)")
        }
        let lines = r.stdout.split(separator: "\n")
        let uname = lines.first?.split(separator: " ").map(String.init) ?? []
        return Platform(os: uname.first ?? "?", machine: uname.dropFirst().first ?? "?",
                        hasSystemd: lines.dropFirst().first == "systemd")
    }

    /// Run on the server with `sh -s`: installs the unit, restarts the
    /// service, waits for its socket, and reports linger and the version.
    static func serviceScript(unit: String) -> String {
        """
        set -e
        unit_dir="$HOME/.config/systemd/user"
        mkdir -p "$unit_dir"
        cat > "$unit_dir/diskindexer.service" <<'DISKINDEXER_UNIT'
        \(unit.trimmingCharacters(in: .newlines))
        DISKINDEXER_UNIT
        systemctl --user daemon-reload
        systemctl --user enable diskindexer >/dev/null 2>&1
        systemctl --user restart diskindexer
        sock="$HOME/.config/diskindexer/server.sock"
        i=0
        while [ ! -S "$sock" ] && [ $i -lt 40 ]; do sleep 0.25; i=$((i+1)); done
        if [ ! -S "$sock" ]; then
          echo "The service didn't start:"
          systemctl --user --no-pager status diskindexer 2>&1 | tail -8
          exit 1
        fi
        user=$(id -un)
        echo "user=$user"
        linger=$(loginctl show-user "$user" -p Linger --value 2>/dev/null || echo unknown)
        if [ "$linger" != yes ] && sudo -n loginctl enable-linger "$user" 2>/dev/null; then linger=yes; fi
        echo "linger=$linger"
        echo "version=$("$HOME/.local/bin/diskindexer" --version)"
        """
    }
}

enum Log {
    static let connect = Logger(subsystem: "com.virajchitnis.diskindexer", category: "connect")
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
