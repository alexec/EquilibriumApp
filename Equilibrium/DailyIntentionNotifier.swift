import Foundation
import UserNotifications

/// Schedules recurring local notifications that nudge the user to set a
/// morning intention (at workday start) and check in (at workday end).
///
/// Uses `UNCalendarNotificationTrigger` so reminders fire even when the app
/// isn't actively refreshing — unlike `WeeklySummaryNotifier`, which fires
/// once immediately when a Monday refresh happens to run.
enum DailyIntentionNotifier {

    static let intentionCategory = "daily-intention"
    static let checkInCategory = "daily-check-in"

    private static let intentionID = "daily-intention-reminder"
    private static let checkInID = "daily-check-in-reminder"

    /// UserInfo key on notification content: `"intention"` or `"checkIn"`.
    static let actionKey = "DailyIntentionNotifier.action"

    /// Requests alert permission and (re)schedules both daily reminders from
    /// the configured workday window.
    ///
    /// Called at launch and whenever preferences change — not on every
    /// refresh. The triggers repeat daily on their own, so re-running this
    /// every five minutes only churned the pending queue (removing and
    /// re-adding identical requests) without changing when anything fires.
    static func reschedule(preferences: WorkPreferences) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.removePendingNotificationRequests(withIdentifiers: [intentionID, checkInID])

            schedule(
                id: intentionID,
                title: "Set today's intention",
                body: "Glance at your meetings, then write goals and outcomes for the day.",
                action: "intention",
                category: intentionCategory,
                hour: preferences.workdayStartHour,
                center: center
            )
            schedule(
                id: checkInID,
                title: "Check in on your day",
                body: "Review your meetings and intention, then note how it went.",
                action: "checkIn",
                category: checkInCategory,
                hour: preferences.workdayEndHour,
                center: center
            )
        }
    }

    // MARK: - Private

    private static func schedule(
        id: String,
        title: String,
        body: String,
        action: String,
        category: String,
        hour: Double,
        center: UNUserNotificationCenter
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Deliberately silent: authorization is requested for `[.alert]` only.
        content.categoryIdentifier = category
        content.userInfo = [actionKey: action]

        // Round to whole minutes *before* splitting into hour/minute.
        // Rounding the fractional part on its own can yield 60 (a workday
        // ending at 17.999 gives minute == 60), which is not a valid
        // `DateComponents` match and would never fire.
        let totalMinutes = max(0, Int((hour * 60).rounded()))
        var components = DateComponents()
        components.hour = (totalMinutes / 60) % 24
        components.minute = totalMinutes % 60

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request)
    }
}
