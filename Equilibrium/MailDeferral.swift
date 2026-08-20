import Foundation

// Deferring is one of the two things people actually do with an inbox item
// they aren't going to action now — the other being to hand it to someone
// else — and it's the one this app supports. "I'll do this on Tuesday" is a
// planning decision, which is what Equilibrium is for.
//
// The date itself is not kept here, or anywhere of ours: it's a reminder in
// Reminders, written by `RemindersStore`, with a `message://` URL pointing
// back at the mail. This file holds only the rule for what that date means
// to the column.

/// The rule the inbox column is filtered by.
///
/// Pure, and separate from the store, so the one thing worth being sure
/// about can be read on its own: **a message is hidden only while its
/// deferral is on a later day than today.** Deferred to today, or to a day
/// that has already passed, and it is on screen — a deferral that has come
/// due is the whole point of having made it, and the failure mode to avoid
/// is work quietly disappearing on the morning it was meant to resurface.
enum MailDeferral {
    static func isHidden(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let date else { return false }
        return calendar.startOfDay(for: date) > calendar.startOfDay(for: now)
    }

    /// Whether this is a deferral that has come back round — worth marking
    /// on the row, so a message reappearing at the top of a quiet inbox
    /// explains itself.
    static func isDueNow(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let date else { return false }
        return calendar.startOfDay(for: date) <= calendar.startOfDay(for: now)
    }

    /// The choices offered, as day offsets. No "later today": today's
    /// deferrals are shown, by the rule above, so it would file a message
    /// under a decision and then leave it exactly where it was.
    enum Choice: String, CaseIterable, Identifiable {
        case tomorrow = "Tomorrow"
        case inThreeDays = "In 3 days"
        case nextWeek = "Next week"

        var id: String { rawValue }

        var days: Int {
            switch self {
            case .tomorrow: return 1
            case .inThreeDays: return 3
            case .nextWeek: return 7
            }
        }

        func date(from now: Date = Date(), calendar: Calendar = .current) -> Date {
            let start = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: days, to: start) ?? start
        }
    }
}
