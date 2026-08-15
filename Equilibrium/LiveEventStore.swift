import Foundation

/// Persists raw `PowerEvent` objects captured by `PowerNotificationMonitor`
/// so they survive app restarts.
///
/// Stored as a flat JSON array keyed by date.  Events older than 30 days
/// are pruned automatically on every save to keep the file small.
final class LiveEventStore {
    private let fileURL: URL

    /// Maximum age of events kept on disk (30 days).
    private static let retentionDays: Double = 30

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("WorkActivityTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("live-events.json")
    }

    /// Returns all persisted live events, oldest-first.
    func load() -> [PowerEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([StoredEvent].self, from: data) else {
            return []
        }
        return stored.compactMap { stored -> PowerEvent? in
            let kind: PowerEvent.Kind
            switch stored.kind {
            case "wake":  kind = .wake
            case "sleep": kind = .sleep
            default: return nil  // skip unrecognised or corrupted entries
            }
            return PowerEvent(kind: kind, date: stored.date)
        }
    }

    /// Appends `newEvents` to the stored list, pruning events older than
    /// `retentionDays`.
    func append(_ newEvents: [PowerEvent]) {
        let cutoff = Date().addingTimeInterval(-Self.retentionDays * 86_400)
        var all = load().filter { $0.date > cutoff }
        all.append(contentsOf: newEvents)
        // Deduplicate by (kind, date rounded to the second) to guard against
        // double-writes across rapid restarts.
        var seen = Set<String>()
        all = all.filter { event in
            let key = "\(event.kind)-\(Int(event.date.timeIntervalSinceReferenceDate))"
            return seen.insert(key).inserted
        }
        let encoded = all.map { StoredEvent(kind: $0.kind == .wake ? "wake" : "sleep", date: $0.date) }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: – Codable representation

    private struct StoredEvent: Codable {
        let kind: String // "wake" or "sleep"
        let date: Date
    }
}

