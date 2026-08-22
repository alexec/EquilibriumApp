import Foundation
import UserNotifications

/// Fires a one-sentence digest notification on Saturday morning, once per
/// week: "Last week: 38h, 1 late night, 1 weekend day worked, longest day
/// Tue 10.5h. Budget this week: 35h."
///
/// Saturday, not Monday, because the app's week *is* Saturday→Friday
/// (`WeekCalendar`). A Monday digest quoted a budget for a week that was
/// already two days old, and measured a Mon–Fri week that no other part of
/// the app draws — so the total in the notification and the total on the
/// chart disagreed for the same week, with nothing on screen to explain the
/// difference. Firing on the first day of the week the budget belongs to
/// makes both figures the week the chart pages to.
///
/// Takes `weeklyTargetHours` (from `WorkPreferences`) for the budget figure
/// and guards against duplicate firing with a UserDefaults key.
enum WeeklySummaryNotifier {

    /// Hours after which an end time is considered a "late night".
    static let lateNightHour: Int = 20

    /// Keyed by the week's Saturday rather than by an ISO week number: an
    /// ISO week rolls over on Monday, which is no longer the day this fires,
    /// and the app has its own idea of which seven days are a week. The key
    /// name changed with it, so a marker left by the old Monday digest can't
    /// suppress the first Saturday one.
    private static let lastFiredWeekKey = "WeeklySummaryNotifier.lastFiredWeekStart"

    // MARK: - Public API

    /// Call this on launch (and after each data refresh). Fires the digest
    /// notification if today is Saturday and we haven't yet fired one for
    /// the week starting today.
    static func fireIfNeeded(
        store: WorkHistoryStore,
        weeklyTargetHours: Double,
        calendar: Calendar = .current,
        today: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        guard isSaturday(today, calendar: calendar) else { return }

        let currentWeek = weekStartKey(for: today, calendar: calendar)
        guard defaults.string(forKey: lastFiredWeekKey) != currentWeek else { return }

        let message = buildMessage(store: store, weeklyTargetHours: weeklyTargetHours, calendar: calendar, today: today)
        scheduleNotification(body: message, weekKey: currentWeek, defaults: defaults)
    }

    // MARK: - Internal helpers (internal for testability)

    static func buildMessage(
        store: WorkHistoryStore,
        weeklyTargetHours: Double,
        calendar: Calendar = .current,
        today: Date = Date()
    ) -> String {
        let spans = store.load()

        let lastWeekDays = WeekCalendar.weekDays(offset: -1, calendar: calendar, today: today)
        // Kept parallel to `lastWeekDays`, holes and all: `WeeklyInsights`
        // pairs a day with its span by position, so compacting the array
        // first would line a Saturday up with some weekday's hours.
        let lastWeekSpans: [WorkdaySpan?] = lastWeekDays.map { spans[dayKey(for: $0, calendar: calendar)] }
        let workedSpans = lastWeekSpans.compactMap { $0 }

        let totalHours = workedSpans.reduce(0.0) { $0 + $1.effectiveHours }
        let lateNights = WeeklyInsights.lateNightCount(
            spans: lastWeekSpans,
            lateNightHour: lateNightHour,
            calendar: calendar
        )
        let weekendDays = WeeklyInsights.weekendWorkCount(
            days: lastWeekDays,
            spans: lastWeekSpans,
            calendar: calendar
        )
        let longestSpan = workedSpans.max(by: { $0.effectiveHours < $1.effectiveHours })

        let totalStr = formatHours(totalHours)
        let budgetStr = formatHours(weeklyTargetHours)

        var parts: [String] = ["Last week: \(totalStr)"]

        if lateNights > 0 {
            parts.append("\(lateNights) late night\(lateNights == 1 ? "" : "s")")
        }

        // The signal the Mon–Fri digest could never carry, and the one this
        // notification exists to catch: hours on days that were supposed to
        // be off.
        if weekendDays > 0 {
            parts.append("\(weekendDays) weekend day\(weekendDays == 1 ? "" : "s") worked")
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

    private static func isSaturday(_ date: Date, calendar: Calendar) -> Bool {
        calendar.component(.weekday, from: date) == 7 // 7 = Saturday
    }

    /// The `dayKey` of the Saturday starting the week containing `date` —
    /// the identity of a week, in the terms the rest of the app uses.
    private static func weekStartKey(for date: Date, calendar: Calendar) -> String {
        let start = WeekCalendar.weekStart(offset: 0, calendar: calendar, today: date)
        return dayKey(for: start, calendar: calendar)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        return fmt.string(from: date)
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
