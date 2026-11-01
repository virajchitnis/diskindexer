import Foundation

public enum Format {
    /// Short size like the TUI: 512B, 1.5K, 20.0M, 1.2G, 3.4T.
    public static func size(_ bytes: Int64) -> String {
        let units = ["B", "K", "M", "G", "T", "P"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes)B" : String(format: "%.1f%@", value, units[unit])
    }

    public static func commas(_ n: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Items per second, as in the CLI progress view.
    public static func rate(processed: Int, elapsed: TimeInterval) -> String {
        guard elapsed > 0, processed > 0 else { return "" }
        let r = Double(processed) / elapsed
        return r >= 1000 ? String(format: "%.1fk/s", r / 1000) : String(format: "%.0f/s", r)
    }

    /// Remaining time estimate, or "" when the total is unknown.
    public static func eta(processed: Int, total: Int, elapsed: TimeInterval) -> String {
        guard total > 0, processed > 0, processed < total, elapsed > 0 else { return "" }
        let remaining = elapsed / Double(processed) * Double(total - processed)
        return "~" + duration(remaining) + " left"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

public extension Job {
    /// Paths that couldn't be read: the final count once done, else so far.
    var errorCount: Int { stats?.errorCount ?? progress.errors ?? 0 }

    var processed: Int { progress.added + progress.updated + progress.skipped }

    /// 0...1 when the phase has a known total, nil for indeterminate.
    /// 0...1 when the phase has a known total, nil (indeterminate) while
    /// running without one. A job that stopped early (cancelled, failed,
    /// interrupted) shows where it stopped rather than a full bar.
    var fraction: Double? {
        if state == .done { return 1 }
        var live: Double?
        switch progress.phase {
        case "indexing" where progress.total > 0:
            live = min(1, Double(processed) / Double(progress.total))
        case "sizes" where progress.dirsTotal > 0:
            live = Double(progress.dirsDone) / Double(progress.dirsTotal)
        default:
            break
        }
        return state == .running ? live : (live ?? 0)
    }

    var phaseTitle: String {
        switch state {
        case .done:
            let n = errorCount
            return n == 0 ? "Done" : "Done, \(n) unreadable"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        case .running:
            switch progress.phase {
            case "loading": return "Loading existing index"
            case "clearing": return "Clearing old index"
            case "indexing": return progress.collection.map { "Indexing \($0)" } ?? "Indexing"
            case "root": return "Indexing files at the top of the disk"
            case "deleting":
                let n = progress.deleting ?? 0
                return n == 0 ? "Checking for removed files" : "Removing \(Format.commas(Int64(n))) files no longer on disk"
            case "sizes": return "Computing folder sizes"
            default: return "Starting"
            }
        }
    }
}

public extension Job {
    /// What the job is reading from: the mount path, or the listed collection
    /// folders when it was started without one.
    var sourceDescription: String {
        if !request.mountPath.isEmpty { return request.mountPath }
        return (request.collections ?? []).map(\.rootPath).joined(separator: ", ")
    }
}
