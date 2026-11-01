import Darwin
import Foundation

struct ProcessFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Collects a pipe's output in the background so the child never blocks on a
/// full pipe, and so stderr can be quoted when something fails.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    init(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                return
            }
            self?.lock.withLock { self?.data.append(chunk) }
        }
    }

    var text: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs a short-lived command and returns its exit status and output.
func runCommand(_ executable: String, _ args: [String]) async throws -> (status: Int32, stdout: String, stderr: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    let outBuf = OutputBuffer(out), errBuf = OutputBuffer(err)
    return try await withCheckedThrowingContinuation { cont in
        p.terminationHandler = { p in
            // Give the readability handlers a moment to drain the pipes.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                cont.resume(returning: (p.terminationStatus, outBuf.text, errBuf.text))
            }
        }
        do {
            try p.run()
        } catch {
            cont.resume(throwing: error)
        }
    }
}

/// Asks the kernel for a free TCP port on the loopback interface.
func freeLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ProcessFailure(message: "socket() failed") }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, len) == 0 && getsockname(fd, sa, &len) == 0
        }
    }
    guard ok else { throw ProcessFailure(message: "Couldn't find a free local port") }
    return UInt16(bigEndian: addr.sin_port)
}

func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 24)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
}
