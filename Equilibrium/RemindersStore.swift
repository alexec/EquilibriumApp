import EventKit
import Foundation

/// Deferrals, kept in Reminders rather than in a file of our own.
///
/// A deferral is "remind me about this on Tuesday", which is precisely what
/// the Reminders app is for. Keeping it in a private JSON file meant a
/// decision you made in Equilibrium existed only in Equilibrium: it didn't
/// reach your phone, it didn't notify you, and it vanished if the file did.
/// A reminder is the same decision written somewhere the whole system
/// already understands.
///
/// **Why not Mail's own Remind Me**, which is the obvious answer: it isn't
/// scriptable. Mail's dictionary has no `remind` command and no property
/// for it on a message — the only message state Apple Events can write is
/// read status, flags, junk status, and which mailbox it's in. Remind Me
/// exists only as a menu item and a swipe. So the date lives in Reminders,
/// and `MailStore.setFlagged` marks the message in Mail so that opening
/// Mail still shows you which messages you've put off.
///
/// The link back is the reminder's `url`, set to the same `message://`
/// address the inbox column opens — so the reminder is clickable straight
/// into the message, and reading the deferrals back is a matter of
/// recognising our own URLs.
final class RemindersStore {
    static let shared = RemindersStore()

    private let store = EKEventStore()

    private init() {}

    // MARK: - Permission

    /// Reminders is its own permission, separate from calendars, and asked
    /// for only when someone first defers something — nobody should be
    /// prompted for access to their reminders by an app they opened to look
    /// at a chart.
    func requestAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .authorized, .fullAccess:
            return true
        case .notDetermined:
            if #available(macOS 14.0, *) {
                return (try? await store.requestFullAccessToReminders()) ?? false
            } else {
                return await withCheckedContinuation { continuation in
                    store.requestAccess(to: .reminder) { granted, _ in
                        continuation.resume(returning: granted)
                    }
                }
            }
        default:
            return false
        }
    }

    var isAuthorized: Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .authorized, .fullAccess: return true
        default: return false
        }
    }

    // MARK: - Reading

    /// Every outstanding deferral, as message id to the day it comes back.
    ///
    /// Only reminders this app wrote are recognised, by the `message://`
    /// URL it puts on them — someone else's shopping list is not a deferred
    /// email, and a reminder without one of our URLs is left alone.
    func deferrals() async -> [String: Date] {
        guard isAuthorized else { return [:] }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: found ?? [])
            }
        }

        var result: [String: Date] = [:]
        for reminder in reminders {
            guard let identifier = MailLinks.messageID(from: reminder.url) else { continue }
            guard let due = reminder.dueDateComponents?.date else { continue }
            // The soonest wins if a message somehow has two: the earlier
            // decision is the one that brings it back first, and showing it
            // early is the harmless direction to be wrong in.
            if let existing = result[identifier], existing <= due { continue }
            result[identifier] = due
        }
        return result
    }

    // MARK: - Writing

    /// Writes "remind me about this message on that day".
    ///
    /// Nine in the morning, not midnight: a reminder that fires as the day
    /// ticks over is one you've already dismissed by the time you could act
    /// on it.
    @discardableResult
    func addReminder(messageID: String, subject: String, note: String?, until date: Date) -> Bool {
        guard let destination = store.defaultCalendarForNewReminders() else { return false }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = destination
        reminder.title = subject
        reminder.notes = note
        reminder.url = MailLinks.messageURL(for: messageID)

        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = 9
        components.minute = 0
        reminder.dueDateComponents = components
        // Without an alarm the reminder is a list entry that never speaks;
        // the point of deferring is to be told, not to remember to look.
        if let fireDate = components.date {
            reminder.addAlarm(EKAlarm(absoluteDate: fireDate))
        }

        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            return false
        }
    }

    /// Drops the reminders for a message — used when a deferral is taken
    /// back, and when the message is archived and the decision stops
    /// applying to anything.
    @discardableResult
    func clear(messageID: String) async -> Bool {
        guard isAuthorized else { return false }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: found ?? [])
            }
        }

        var removedAny = false
        for reminder in reminders where MailLinks.messageID(from: reminder.url) == messageID {
            // Removed rather than marked complete. "Completed" would claim
            // you dealt with the message, which taking back a deferral
            // says nothing about.
            if (try? store.remove(reminder, commit: false)) != nil {
                removedAny = true
            }
        }
        if removedAny { try? store.commit() }
        return removedAny
    }
}
