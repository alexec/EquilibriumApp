import AppKit
import UserNotifications

/// Bridges UserNotifications taps into the SwiftUI app: when the user clicks
/// a morning-intention or evening-check-in notification, open the main window
/// and present the matching sheet.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private let onAction: (String?) -> Void

    /// Set from a view that has `@Environment(\.openWindow)` so notification
    /// taps can open the main window even when no window is visible yet.
    var openMainWindow: (() -> Void)?

    init(onAction: @escaping (String?) -> Void) {
        self.onAction = onAction
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banners even while Equilibrium is frontmost.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.notification.request.content.userInfo[DailyIntentionNotifier.actionKey] as? String
        DispatchQueue.main.async {
            self.openMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
            self.onAction(action)
        }
        completionHandler()
    }
}
