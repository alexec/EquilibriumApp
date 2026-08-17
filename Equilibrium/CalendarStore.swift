import EventKit
import Foundation

/// Wraps EventKit calendar access: requests permission once, then exposes
/// synchronous (main-thread-safe) helpers for reading meeting events.
final class CalendarStore {
    static let shared = CalendarStore()

    private let store = EKEventStore()

    /// Identifier of the calendar to read, or `nil` to read all of them.
    /// Seeded from `CalendarSelectionStore` and updated when the user edits
    /// the picker in preferences.
    private var selectedIdentifier: String?

    private init() {
        selectedIdentifier = CalendarSelectionStore.load()
    }

    // MARK: - Calendar selection

    /// The calendars the user can choose between, grouped-ready (sorted by
    /// account, then title). Returns `[]` when access hasn't been granted.
    func availableCalendars() -> [SelectableCalendar] {
        store.calendars(for: .event)
            .map { calendar in
                SelectableCalendar(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source?.title ?? "Other",
                    colorComponents: calendar.cgColor?.components.map { $0.map(Double.init) }
                )
            }
            .sorted {
                $0.sourceTitle == $1.sourceTitle
                    ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    : $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending
            }
    }

    /// The chosen calendar, or `nil` if the user has never picked one.
    var selection: String? { selectedIdentifier }

    /// Records an explicit calendar choice. Pass `nil` to revert to reading
    /// every calendar.
    func updateSelection(_ identifier: String?) {
        selectedIdentifier = identifier
        if let identifier {
            CalendarSelectionStore.save(identifier)
        } else {
            CalendarSelectionStore.clear()
        }
    }

    /// Resolves `selectedIdentifier` to a live `EKCalendar` for use as a
    /// query predicate's scope.
    ///
    /// Returns `nil` — meaning "every calendar" to EventKit — only when the
    /// user has made no explicit choice. A chosen calendar that no longer
    /// resolves (deleted or unsubscribed since it was picked) yields an
    /// empty scope, so the app reads nothing rather than silently falling
    /// back to reading everything; `CalendarPickerView` surfaces that state.
    private func scopedCalendars() -> [EKCalendar]? {
        guard let selectedIdentifier else { return nil }
        return [store.calendar(withIdentifier: selectedIdentifier)].compactMap { $0 }
    }

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

        // An explicit selection that resolves to no calendars means "read
        // nothing". Short-circuit rather than passing an empty array to
        // EventKit, which documents only `nil` as the all-calendars value
        // and leaves the empty case undefined.
        let scope = scopedCalendars()
        if let scope, scope.isEmpty { return [] }

        let predicate = store.predicateForEvents(
            withStart: startOfDay,
            end: endOfDay,
            calendars: scope
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

    /// Title-preserving meeting list for intention / check-in UI (not merged).
    func dayMeetings(on date: Date) -> [DayMeeting] {
        meetingEvents(on: date)
            .compactMap { event -> DayMeeting? in
                guard let start = event.startDate, let end = event.endDate, start < end else {
                    return nil
                }
                let title = (event.title?.trimmingCharacters(in: .whitespacesAndNewlines))
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled meeting"
                let id = event.eventIdentifier ?? "\(title)-\(start.timeIntervalSinceReferenceDate)"
                return DayMeeting(id: id, title: title, start: start, end: end)
            }
            .sorted { $0.start < $1.start }
    }
}
