import Foundation

/// Finds somewhere to put an hour of work.
///
/// Pure and free of I/O, like `MeetingCalculator` and `WorkloadRecommender`
/// — it's handed the busy intervals and the shape of the working day and
/// returns a slot, so the rule can be read on its own.
///
/// The rule: the earliest gap, inside a shift, long enough to hold the
/// block, on or before the day it's due. Earliest rather than best-fit
/// because work put off drifts, and the block is a promise to yourself
/// that the sooner it's kept the more likely it is to survive.
enum TimeBlockPlanner {
    /// How long a block is unless something says otherwise. An hour is
    /// enough to finish most things a message asks for, and short enough
    /// that a day can hold two or three without becoming a diary.
    static let defaultMinutes = 60

    /// A slot that could be claimed.
    struct Slot: Equatable {
        let start: Date
        let end: Date

        var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
    }

    /// Where to put `minutes` of work, given what's already in the diary.
    ///
    /// - Parameters:
    ///   - busy: intervals already taken on the days considered. Meetings
    ///     and existing blocks alike — anything already on the calendar is
    ///     a reason not to put work there.
    ///   - shifts: the working day, from `WorkPreferences`. Blocks land
    ///     inside working hours or not at all: an app that answers "when
    ///     shall I do this" with half past nine at night is not helping.
    ///   - days: the days to consider, in the order to consider them.
    ///   - now: nothing is scheduled in the past, and nothing in the next
    ///     few minutes either — a block starting two minutes from now is
    ///     one you've already missed.
    static func firstSlot(
        minutes: Int = defaultMinutes,
        busy: [(start: Date, end: Date)],
        shifts: [ShiftTemplate],
        days: [Date],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Slot? {
        let duration = TimeInterval(max(1, minutes) * 60)
        // Rounded up to the next quarter hour: a block starting at 14:03
        // reads as an accident, and the diary it joins is drawn on the
        // quarter hour anyway.
        let earliest = nextQuarterHour(after: now, calendar: calendar)

        for day in days {
            let startOfDay = calendar.startOfDay(for: day)
            for shift in shifts.sorted(by: { $0.startHour < $1.startHour }) {
                guard let window = window(for: shift, on: startOfDay, calendar: calendar) else { continue }
                let from = max(window.start, earliest)
                guard from < window.end else { continue }

                if let slot = firstGap(
                    from: from,
                    until: window.end,
                    duration: duration,
                    busy: busy
                ) {
                    return slot
                }
            }
        }
        return nil
    }

    /// The first `duration`-long stretch between `from` and `until` that
    /// nothing else occupies.
    private static func firstGap(
        from: Date,
        until: Date,
        duration: TimeInterval,
        busy: [(start: Date, end: Date)]
    ) -> Slot? {
        // Only what overlaps the window matters, and in time order — the
        // caller's list is whatever EventKit handed back.
        let relevant = busy
            .filter { $0.end > from && $0.start < until }
            .sorted { $0.start < $1.start }

        var cursor = from
        for interval in relevant {
            if interval.start.timeIntervalSince(cursor) >= duration {
                return Slot(start: cursor, end: cursor.addingTimeInterval(duration))
            }
            // Overlapping events are already merged by walking forward to
            // the furthest end seen rather than to this one's.
            cursor = max(cursor, interval.end)
            if cursor >= until { return nil }
        }
        guard until.timeIntervalSince(cursor) >= duration else { return nil }
        return Slot(start: cursor, end: cursor.addingTimeInterval(duration))
    }

    /// A shift template turned into real times on a real day.
    private static func window(
        for shift: ShiftTemplate,
        on startOfDay: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date)? {
        let start = startOfDay.addingTimeInterval(shift.startHour * 3600)
        let end = startOfDay.addingTimeInterval(shift.endHour * 3600)
        guard start < end else { return nil }
        return (start, end)
    }

    private static func nextQuarterHour(after date: Date, calendar: Calendar) -> Date {
        let quarter: TimeInterval = 15 * 60
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / quarter).rounded(.up) * quarter)
    }

    /// What's left of this week, today included.
    ///
    /// The whole horizon for blocking time out. Equilibrium is a week at a
    /// time — the chart is a week, the target is a week, the review is a
    /// week — and work pushed into next week isn't planning, it's deferral
    /// wearing a hat. If it won't fit before Friday, that is worth finding
    /// out now rather than discovering it on Friday.
    ///
    /// The week is Saturday-to-Friday (`WeekCalendar`), so on a Sunday this
    /// is nearly the whole of it and on a Friday it's just today.
    static func remainingWeekDays(now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return WeekCalendar.currentWeekDays(calendar: calendar, today: now)
            .filter { calendar.startOfDay(for: $0) >= today }
    }

    /// The times a block could start on one day: every half hour inside a
    /// shift with room for the whole block after it.
    ///
    /// Half hours rather than every hour, because a meeting ending at half
    /// past leaves half an hour that an hourly grid can't see; and rather
    /// than every minute, because a list of choices is only useful if you
    /// can read it.
    ///
    /// `isFree` comes back alongside each one instead of the busy ones
    /// being dropped: a diary with something already in it at every hour
    /// should say so, not present an empty list.
    static func startTimes(
        on day: Date,
        minutes: Int,
        shifts: [ShiftTemplate],
        busy: [(start: Date, end: Date)],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [(start: Date, isFree: Bool)] {
        let duration = TimeInterval(max(1, minutes) * 60)
        let startOfDay = calendar.startOfDay(for: day)
        let earliest = nextQuarterHour(after: now, calendar: calendar)

        var times: [(start: Date, isFree: Bool)] = []
        for shift in shifts.sorted(by: { $0.startHour < $1.startHour }) {
            guard let window = window(for: shift, on: startOfDay, calendar: calendar) else { continue }
            var candidate = window.start
            while candidate.addingTimeInterval(duration) <= window.end {
                if candidate >= earliest {
                    let end = candidate.addingTimeInterval(duration)
                    let free = !busy.contains { $0.start < end && $0.end > candidate }
                    times.append((candidate, free))
                }
                candidate = candidate.addingTimeInterval(30 * 60)
            }
        }
        return times
    }
}
