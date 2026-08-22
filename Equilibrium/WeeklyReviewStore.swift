import Foundation

/// Persists one answer per week as JSON under Application Support,
/// mirroring `DailyIntentionStore`.
///
/// Never pruned, unlike the power events and the mail summaries. A week's
/// hours can be recomputed from data that ages out; what you thought of
/// that week can't be recovered from anywhere, and the whole point of
/// asking is to be able to look back over a year of answers.
final class WeeklyReviewStore {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("WorkActivityTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("weekly-reviews.json")
    }

    func load() -> [String: WeeklyReview] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        guard let decoded = try? JSONDecoder().decode([String: WeeklyReview].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func save(_ reviews: [String: WeeklyReview]) {
        guard let data = try? JSONEncoder().encode(reviews) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    func upsert(_ review: WeeklyReview) -> [String: WeeklyReview] {
        var all = load()
        all[review.weekKey] = review
        save(all)
        return all
    }

    /// Drops a week's answer entirely, for an answer cleared back to
    /// nothing — an empty record would otherwise count as an answered week.
    @discardableResult
    func remove(weekKey: String) -> [String: WeeklyReview] {
        var all = load()
        all.removeValue(forKey: weekKey)
        save(all)
        return all
    }
}
