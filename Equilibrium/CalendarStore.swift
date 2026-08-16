import EventKit
import Foundation

/// Wraps EventKit calendar access: requests permission once, then exposes
/// synchronous (main-thread-safe) helpers for reading meeting events.
final class CalendarStore {
    static let shared = CalendarStore()

    private let store = EKEventStore()

    private init() {}

    // MARK: - Permission

    /// Requests calendar access if not already determined.
    /// Calls `completion` on the main actor with `true` if access was granted.
    func requestAccess() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            return true
        case .notDetermined:
            if #available(macOS 14.0, *) {
                return (try? await store.requestFullAccessToEvents()) ?? false
            } else {
                return await withCheckedContinuation { continuation in
                    store.requestAccess(to: .event) { granted, _ in
                        continuation.resume(returning: granted)
                    }
                }
            }
        default:
            return false
        }
    }

    // MARK: - Meeting Events

    /// Returns all meeting events on `date` (no workday clipping). All-day
    /// events and events marked as "free" are excluded, since they represent
    /// blocked-off time rather than actual attended meetings.
    func meetingEvents(on date: Date) -> [EKEvent] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }

        let predicate = store.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: nil
        )

        return store.events(matching: predicate).filter { event in
            guard !event.isAllDay else { return false }
            guard event.availability != .free else { return false }
            return event.startDate != nil && event.endDate != nil
        }
    }

    /// Returns meeting events on `date` whose time overlaps `span`.
    func meetingEvents(on date: Date, span: WorkdaySpan) -> [EKEvent] {
        meetingEvents(on: date).filter { event in
            guard let start = event.startDate, let end = event.endDate else { return false }
            return start < span.end && end > span.start
        }
    }
}
