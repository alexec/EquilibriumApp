import Foundation
import UserNotifications

/// Fires a one-sentence Monday-morning digest notification once per ISO week:
/// "Last week: 38h, 1 late night, longest day Tue 10.5h. Budget this week: 35h."
///
/// Takes `weeklyTargetHours` (from `WorkPreferences`) for the budget figure
/// and guards against duplicate firing with a UserDefaults key.
enum WeeklySummaryNotifier {

    /// Hours after which an end time is considered a "late night".
    static let lateNightHour: Int = 20

    private static let lastFiredWeekKey = "WeeklySummaryNotifier.lastFiredISOWeek"

    // MARK: - Public API

    /// Call this on launch (and after each data refresh). Fires the digest
    /// notification if today is Monday and we haven't yet fired one this week.
    static func fireIfNeeded(
        store: WorkHistoryStore,
        weeklyTargetHours: Double,
        calendar: Calendar = .current,
        today: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard isMonday(today, calendar: calendar) else { return }

        let currentISOWeek = isoWeekIdentifier(for: today, calendar: calendar)
        guard defaults.string(forKey: lastFiredWeekKey) != currentISOWeek else { return }

        let message = buildMessage(store: store, weeklyTargetHours: weeklyTargetHours, calendar: calendar, today: today)
        scheduleNotification(body: message, weekKey: currentISOWeek, defaults: defaults)
    }

    // MARK: - Internal helpers (internal for testability)

    static func buildMessage(
        store: WorkHistoryStore,
        weeklyTargetHours: Double,
        calendar: Calendar = .current,
        today: Date = Date()
    ) -> String {
        let spans = store.load()

        let lastWeekDays = lastWeekWeekdays(today: today, calendar: calendar)
        let lastWeekSpans = lastWeekDays.compactMap { spans[dayKey(for: $0, calendar: calendar)] }

        let totalHours = lastWeekSpans.reduce(0.0) { $0 + $1.effectiveHours }
        let lateNights = lastWeekSpans.filter { isLateNight($0, calendar: calendar) }.count
        let longestSpan = lastWeekSpans.max(by: { $0.effectiveHours < $1.effectiveHours })

        let totalStr = formatHours(totalHours)
        let budgetStr = formatHours(weeklyTargetHours)

        var parts: [String] = ["Last week: \(totalStr)"]

        if lateNights > 0 {
            parts.append("\(lateNights) late night\(lateNights == 1 ? "" : "s")")
        }

        if let longest = longestSpan {
            let dayAbbr = dayAbbreviation(for: longest.dayKey, calendar: calendar)
            let hoursStr = formatHours(longest.effectiveHours)
            parts.append("longest day \(dayAbbr) \(hoursStr)")
        }

        let lastWeekSummary = parts.joined(separator: ", ")
        return "\(lastWeekSummary). Budget this week: \(budgetStr)."
    }

    // MARK: - Private helpers

    private static func isMonday(_ date: Date, calendar: Calendar) -> Bool {
        calendar.component(.weekday, from: date) == 2 // 2 = Monday
    }

    private static func isoWeekIdentifier(for date: Date, calendar: Calendar) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.locale = Locale(identifier: "en_US_POSIX")
        let week = iso.component(.weekOfYear, from: date)
        let year = iso.component(.yearForWeekOfYear, from: date)
        return String(format: "%04d-W%02d", year, week)
    }

    /// The five weekdays (Mon–Fri) of the previous calendar week.
    private static func lastWeekWeekdays(today: Date, calendar: Calendar) -> [Date] {
        let monday = calendar.startOfDay(for: today)
        // Offsets from this Monday to last week's Mon–Fri: -7, -6, -5, -4, -3
        return (3...7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: monday)
        }
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        return fmt.string(from: date)
    }

    private static func isLateNight(_ span: WorkdaySpan, calendar: Calendar) -> Bool {
        let endHour = calendar.component(.hour, from: span.end)
        return endHour >= lateNightHour
    }

    private static func formatHours(_ hours: Double) -> String {
        HoursFormat.string(hours)
    }

    private static func dayAbbreviation(for dayKey: String, calendar: Calendar) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        guard let date = fmt.date(from: dayKey) else { return dayKey }
        let abbr = DateFormatter()
        abbr.dateFormat = "EEE"
        abbr.calendar = calendar
        abbr.locale = Locale(identifier: "en_US_POSIX")
        return abbr.string(from: date)
    }

    private static func scheduleNotification(body: String, weekKey: String, defaults: UserDefaults) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Weekly Summary"
            content.body = body
            let request = UNNotificationRequest(
                identifier: "weekly-summary",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                guard error == nil else { return }
                defaults.set(weekKey, forKey: lastFiredWeekKey)
            }
        }
    }
}
