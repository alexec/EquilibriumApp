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

    /// A plain-English sentence describing these settings, generated from
    /// the struct's fields — this is what `PreferencesView` shows in place
    /// of a form of Steppers, mirroring the free-text description that
    /// produced it (or that it defaults to before you've described one).
    var summarySentence: String {
        var parts = [
            "\(HoursFormat.string(weeklyTargetHours))/week",
            "\(Self.clockLabel(workdayStartHour))–\(Self.clockLabel(workdayEndHour))",
        ]
        if let targetMeetingHoursPerDay {
            parts.append("\(HoursFormat.string(targetMeetingHoursPerDay)) meetings/day")
        }
        if let targetFocusHoursPerDay {
            parts.append("\(HoursFormat.string(targetFocusHoursPerDay)) focus/day")
        }
        return parts.joined(separator: ", ") + "."
    }

    private static func clockLabel(_ hour: Double) -> String {
        let period = hour < 12 || hour == 24 ? "am" : "pm"
        let displayHour = hour == 0 || hour == 24 ? 12 : (hour > 12 ? hour - 12 : hour)
        return "\(Int(displayHour))\(period)"
    }
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
