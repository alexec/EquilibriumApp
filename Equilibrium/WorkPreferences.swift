import Foundation

/// The user's configured work-schedule preferences — either set manually or
/// parsed from a free-text description via the on-device LLM (see
/// `WorkPreferencesGenerator`). Drives `WorkloadRecommender`'s weekly
/// target and the "workday track" drawn on each day's bar.
struct WorkPreferences: Codable, Equatable {
    var weeklyTargetHours: Double = 40
    var workdayStartHour: Double = 9
    var workdayEndHour: Double = 17
    /// Desired meetings/day, if the person expressed one. Not yet consumed
    /// anywhere in the UI beyond being stored and shown back in the
    /// preferences editor — a natural follow-up would be comparing it
    /// against the actual per-week meeting average.
    var targetMeetingHoursPerDay: Double?
    /// Desired focused/deep-work hours/day, if the person expressed one.
    /// Same status as `targetMeetingHoursPerDay` above.
    var targetFocusHoursPerDay: Double?

    static let `default` = WorkPreferences()
}

/// Persists `WorkPreferences` as a single JSON blob in UserDefaults —
/// unlike `WorkHistoryStore`'s growing daily history, this is one small
/// struct that only ever has its latest value read, so UserDefaults is
/// simpler than a dedicated file.
enum WorkPreferencesStore {
    private static let key = "WorkPreferences.current"

    static func load(defaults: UserDefaults = .standard) -> WorkPreferences {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(WorkPreferences.self, from: data) else {
            return .default
        }
        return decoded
    }

    static func save(_ preferences: WorkPreferences, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
