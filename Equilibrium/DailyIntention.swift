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
    /// The call to join, where the invitation carries one (see
    /// `MeetingLinks`). Nil for meetings that are just a room and a time.
    var joinURL: URL?
    /// EventKit's identifier for the event, so Calendar can be asked to
    /// show this one rather than just the day — and so it can be deleted.
    /// Shared by every occurrence of a repeating meeting, which is why
    /// `CalendarStore.delete` wants the start time as well.
    var eventIdentifier: String?
    /// Whether this is one occurrence of a repeating meeting. Only the
    /// delete confirmation asks: it's the difference between removing this
    /// Thursday's standup and removing every standup from here on.
    var isRecurring: Bool = false
    /// Who called the meeting. Nil for an event you made yourself, which
    /// EventKit leaves without an organiser.
    var organizer: Person?
    /// Everyone else invited, you and the organiser excluded — the `+n`
    /// beside the title, and the secondary people in the strip below.
    var participants: [Person] = []

    var durationMinutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60.0))
    }
}
