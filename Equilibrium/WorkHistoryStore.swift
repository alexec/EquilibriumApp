import Foundation

/// Persists computed workday spans to disk, keyed by day, so history
/// accumulates across launches even after macOS rolls off old pmset log data.
final class WorkHistoryStore {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("WorkActivityTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
    }

    func load() -> [String: WorkdaySpan] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        guard let spans = try? JSONDecoder().decode([String: WorkdaySpan].self, from: data) else { return [:] }
        return spans
    }

    func save(_ spans: [String: WorkdaySpan]) {
        guard let data = try? JSONEncoder().encode(spans) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Merges freshly computed spans into stored history. Manually-edited
    /// days are never overwritten. Otherwise, the most recent two days are
    /// always overwritten (still in progress / just finished); older days
    /// are only added if not already present, since old entries won't
    /// recompute once their source wake data ages out of pmset's log.
    func merge(freshSpans: [WorkdaySpan], today: String, yesterday: String) -> [String: WorkdaySpan] {
        var stored = load()
        for span in freshSpans {
            if stored[span.dayKey]?.isManual == true { continue }
            if span.dayKey == today || span.dayKey == yesterday || stored[span.dayKey] == nil {
                var newSpan = span
                // A manual meeting/focus split (dragged on the bar) survives
                // the automatic recompute — only start/end/break come from
                // the fresh wake-data pass.
                newSpan.manualMeetingMinutes = stored[span.dayKey]?.manualMeetingMinutes
                stored[span.dayKey] = newSpan
            }
        }
        save(stored)
        return stored
    }

    /// Sets a manually-edited span for a single day, protected from future
    /// automatic overwrites.
    func setManualSpan(_ span: WorkdaySpan) -> [String: WorkdaySpan] {
        var stored = load()
        var manualSpan = span
        manualSpan.isManual = true
        stored[span.dayKey] = manualSpan
        save(stored)
        return stored
    }

    /// Removes a manual override, letting the day revert to being computed
    /// automatically again (it will simply have no data until recomputed).
    func clearManualSpan(dayKey: String) -> [String: WorkdaySpan] {
        var stored = load()
        stored.removeValue(forKey: dayKey)
        save(stored)
        return stored
    }
}
