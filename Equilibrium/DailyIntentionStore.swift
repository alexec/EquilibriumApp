import Foundation

/// Persists per-day intentions and check-ins as JSON under Application Support,
/// mirroring `WorkHistoryStore`.
final class DailyIntentionStore {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("WorkActivityTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("daily-intentions.json")
    }

    func load() -> [String: DailyIntention] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: DailyIntention].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func save(_ intentions: [String: DailyIntention]) {
        guard let data = try? JSONEncoder().encode(intentions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    func upsert(_ intention: DailyIntention) -> [String: DailyIntention] {
        var all = load()
        all[intention.dayKey] = intention
        save(all)
        return all
    }
}
