import Foundation

/// Pure date-range math for the app's European-style week (Saturday through
/// Friday, so Sat/Sun start the week they belong to).
enum WeekCalendar {
    static func isWeekend(_ date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7 // Sunday or Saturday
    }

    /// The Saturday starting the week `offset` weeks away from the one
    /// containing `today` — 0 is this week, -1 last week, and so on. The
    /// chart shows exactly one of these at a time; stepping back through
    /// history is a matter of decrementing `offset`.
    static func weekStart(offset: Int = 0, calendar: Calendar = .current, today: Date = .init()) -> Date {
        let startOfToday = calendar.startOfDay(for: today)
        let weekdayOfToday = calendar.dateComponents([.weekday], from: startOfToday).weekday ?? 1 // 1=Sun...7=Sat
        let daysSinceSaturday = (weekdayOfToday - 7 + 7) % 7
        guard let currentWeekStart = calendar.date(byAdding: .day, value: -daysSinceSaturday, to: startOfToday),
              let start = calendar.date(byAdding: .day, value: 7 * offset, to: currentWeekStart) else {
            return startOfToday
        }
        return start
    }

    /// The full Saturday-through-Friday range of the week `offset` weeks
    /// from this one, including days still in the future.
    ///
    /// Always exactly seven days: callers index `days` and `spans` in step,
    /// so a short array would silently pair a day with another day's hours.
    /// Day arithmetic doesn't realistically fail, but where it did, repeating
    /// the week's first day keeps the count right rather than dropping a
    /// column.
    static func weekDays(offset: Int = 0, calendar: Calendar = .current, today: Date = .init()) -> [Date] {
        let start = weekStart(offset: offset, calendar: calendar, today: today)
        return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start) ?? start }
    }

    /// This week's full Saturday-through-Friday range, including future days.
    static func currentWeekDays(calendar: Calendar = .current, today: Date = .init()) -> [Date] {
        weekDays(offset: 0, calendar: calendar, today: today)
    }
}
