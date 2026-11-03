import DiskIndexerKit
import Foundation

/// Runs the bundled diskindexer as a child process on a random loopback port,
/// protected by a random token. The child watches its stdin and exits when the
/// app does, even if the app crashes.
final class LocalBackend: Transport {
    let displayName = "This Mac"
    let isLocal = true
    var onDisconnect: (@Sendable (String) -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private let stopping = AtomicFlag()

    /// The bundled binary, falling back to $DISKINDEXER_BIN or a PATH lookup
    /// so `swift run` works during development.
    static func binaryURL() -> URL? {
        if let url = Bundle.main.url(forResource: "diskindexer", withExtension: nil) {
            return url
        }
        let env = ProcessInfo.processInfo.environment
        if let p = env["DISKINDEXER_BIN"], FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent("diskindexer")
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    func connect() async throws -> Endpoint {
        guard let bin = Self.binaryURL() else {
            throw ProcessFailure(message: "The diskindexer binary wasn't found in the app bundle or on your PATH.")
        }
        stopping.set(false)
        let token = randomToken()
        let p = Process()
        p.executableURL = bin
        p.arguments = ["serve", "--listen", "127.0.0.1:0", "--stdin-watch"]
        var env = ProcessInfo.processInfo.environment
        // Development hook: point local mode at a scratch index.
        if let db = env["DISKINDEXER_DB"], !db.isEmpty {
            p.arguments! += ["--db", db]
        }
        env["DISKINDEXER_TOKEN"] = token
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        let errBuf = OutputBuffer(stderr)
        p.terminationHandler = { [weak self] proc in
            guard let self, !self.stopping.isSet else { return }
            self.onDisconnect?("diskindexer exited (status \(proc.terminationStatus)). \(errBuf.text)")
        }
        try p.run()
        process = p
        stdinPipe = stdin

        // The server prints {"listen":"127.0.0.1:PORT"} once it's ready.
        let addr = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    if let data = line.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       let addr = obj["listen"] {
                        return addr
                    }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let addr, let url = URL(string: "http://\(addr)/") else {
            disconnect()
            throw ProcessFailure(message: "diskindexer didn't start. \(errBuf.text)")
        }
        return Endpoint(baseURL: url, token: token)
    }

    func disconnect() {
        stopping.set(true)
        process?.terminate()
        try? stdinPipe?.fileHandleForWriting.close()
        process = nil
        stdinPipe = nil
    }
}
