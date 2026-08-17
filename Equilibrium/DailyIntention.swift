import Foundation

/// One day's morning intention (goals + outcomes) and optional end-of-day
/// check-in. Keyed by the same `yyyy-MM-dd` day keys used for work spans.
struct DailyIntention: Codable, Equatable, Identifiable {
    var id: String { dayKey }
    let dayKey: String

    /// What the person wants to accomplish today.
    var goals: String = ""
    /// What success looks like by end of day.
    var outcomes: String = ""
    var intentionSetAt: Date?

    /// Free-text reflection captured at check-in.
    var checkInReflection: String = ""
    var checkedInAt: Date?

    var hasIntention: Bool {
        !goals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !outcomes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCheckIn: Bool {
        checkedInAt != nil
            || !checkInReflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        dayKey: String,
        goals: String = "",
        outcomes: String = "",
        intentionSetAt: Date? = nil,
        checkInReflection: String = "",
        checkedInAt: Date? = nil
    ) {
        self.dayKey = dayKey
        self.goals = goals
        self.outcomes = outcomes
        self.intentionSetAt = intentionSetAt
        self.checkInReflection = checkInReflection
        self.checkedInAt = checkedInAt
    }
}

/// A calendar meeting for intention / check-in lists — keeps title (unlike
/// chart `MeetingBlock`s, which merge intervals and drop EventKit metadata).
struct DayMeeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date

    var durationMinutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60.0))
    }
}
