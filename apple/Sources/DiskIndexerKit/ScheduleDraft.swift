import Foundation

/// Editable state for the schedule editor: a new schedule for a disk or
/// collection, or an existing one.
struct ScheduleDraft: Identifiable {
    enum Unit: Int, CaseIterable, Identifiable {
        case hours = 1, days = 24, weeks = 168
        var id: Int { rawValue }
        func title(_ n: Int) -> String {
            switch self {
            case .hours: n == 1 ? "hour" : "hours"
            case .days: n == 1 ? "day" : "days"
            case .weeks: n == 1 ? "week" : "weeks"
            }
        }
    }

    let id = UUID()
    var existing: Schedule?
    var db: String?
    var disk: String
    var collection: String?
    /// For a collection: where it was last indexed from, used when path is empty.
    var savedLocation = ""
    /// The disk's mount path, or the folder to read a collection from.
    var path = ""
    var every = 1
    var unit = Unit.days
    var useTime = true
    /// Hour and minute of `at`; only those components are used.
    var time = ScheduleDraft.clock(3, 0)
    var enabled = true

    var isCollection: Bool { collection != nil }

    /// A new schedule for a disk, or for one of its collections.
    init(node: DiskNode, collection: Collection? = nil) {
        disk = node.label
        db = collection?.db ?? node.disks.first?.db
        if let collection {
            self.collection = collection.label
            savedLocation = collection.rootPath
        } else {
            path = node.guessedMountPath ?? ""
        }
    }

    init(editing s: Schedule, savedLocation: String = "") {
        existing = s
        db = s.db
        disk = s.disk
        collection = s.isCollection ? s.collection : nil
        self.savedLocation = savedLocation
        path = s.path ?? ""
        enabled = s.enabled
        let h = s.intervalHours
        if h % Unit.weeks.rawValue == 0 {
            (every, unit) = (h / Unit.weeks.rawValue, .weeks)
        } else if h % Unit.days.rawValue == 0 {
            (every, unit) = (h / Unit.days.rawValue, .days)
        } else {
            (every, unit) = (h, .hours)
        }
        if let at = s.at, let (hh, mm) = Self.parse(at) {
            time = Self.clock(hh, mm)
        } else {
            useTime = false
        }
    }

    var intervalHours: Int { max(1, every) * unit.rawValue }

    /// A time of day only makes sense for whole days.
    var timeApplies: Bool { unit != .hours }

    var at: String? {
        guard useTime && timeApplies else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    var title: String {
        if let collection { return "Reindex \u{201C}\(collection)\u{201D} on \u{201C}\(disk)\u{201D}" }
        return "Reindex \u{201C}\(disk)\u{201D}"
    }

    var request: ScheduleRequest {
        let p = path.trimmingCharacters(in: .whitespaces)
        return ScheduleRequest(db: db, disk: disk, collection: collection,
                               // A collection read from its saved location sends no path.
                               path: p.isEmpty || (isCollection && p == savedLocation) ? nil : p,
                               intervalHours: intervalHours, at: at, enabled: enabled)
    }

    /// A disk needs its mount path; a collection can use its saved location.
    var isValid: Bool {
        every >= 1 && (isCollection || !path.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    static func clock(_ h: Int, _ m: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: h, minute: m)) ?? Date()
    }

    static func parse(_ at: String) -> (Int, Int)? {
        let parts = at.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }
}
