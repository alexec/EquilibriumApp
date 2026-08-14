import Foundation

/// Pure date-range math for the app's European-style week (Saturday through
/// Friday, so Sat/Sun start the week they belong to).
enum WeekCalendar {
    static func isWeekend(_ date: Date, calendar: Calendar = .current) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7 // Sunday or Saturday
    }

    /// A rolling window of full Sat-Fri weeks ending with the current week
    /// (including its future days), covering `weeks` weeks total.
    static func rollingWindowDays(weeks: Int, calendar: Calendar = .current, today: Date = .init()) -> [Date] {
        let startOfToday = calendar.startOfDay(for: today)
        let weekdayOfToday = calendar.dateComponents([.weekday], from: startOfToday).weekday ?? 1 // 1=Sun...7=Sat
        let daysSinceSaturday = (weekdayOfToday - 7 + 7) % 7
        guard let currentWeekStart = calendar.date(byAdding: .day, value: -daysSinceSaturday, to: startOfToday) else {
            return [startOfToday]
        }
        guard let windowStart = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: currentWeekStart) else {
            return [startOfToday]
        }

        var days: [Date] = []
        var cursor = windowStart
        for _ in 0..<(weeks * 7) {
            days.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        return days
    }

    /// This week's full Saturday-through-Friday range, including future days.
    static func currentWeekDays(calendar: Calendar = .current, today: Date = .init()) -> [Date] {
        rollingWindowDays(weeks: 1, calendar: calendar, today: today)
    }
}
