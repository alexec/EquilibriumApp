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
    /// the configured workday window. Safe to call on every refresh / prefs change.
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
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = [actionKey: action]

        var components = DateComponents()
        components.hour = Int(hour)
        components.minute = Int((hour.truncatingRemainder(dividingBy: 1) * 60).rounded())

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        center.add(request)
    }
}
