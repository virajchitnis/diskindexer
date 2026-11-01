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
    var processed: Int { progress.added + progress.updated + progress.skipped }

    /// 0...1 when the phase has a known total, nil for indeterminate.
    var fraction: Double? {
        switch progress.phase {
        case "indexing" where progress.total > 0:
            return min(1, Double(processed) / Double(progress.total))
        case "sizes" where progress.dirsTotal > 0:
            return Double(progress.dirsDone) / Double(progress.dirsTotal)
        default:
            return state == .running ? nil : 1
        }
    }

    var phaseTitle: String {
        switch state {
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .running:
            switch progress.phase {
            case "clearing": return "Clearing old index"
            case "indexing": return progress.collection.map { "Indexing \($0)" } ?? "Indexing"
            case "sizes": return "Computing folder sizes"
            default: return "Starting"
            }
        }
    }
}
