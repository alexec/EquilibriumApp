import EventKit
import Foundation

extension Person {
    /// EventKit describes a participant by a URL, which for a person is
    /// always `mailto:` — the same address a message would arrive from, so
    /// the organiser of your 3pm and the sender of this morning's email
    /// resolve to one person rather than two.
    init?(participant: EKParticipant) {
        let address = participant.url.absoluteString
            .replacingOccurrences(of: "mailto:", with: "")
        guard address.contains("@") else { return nil }
        self.init(address: address, name: participant.name)
    }
}

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

    /// Every attended meeting between two dates, flattened for
    /// `MeetingCost`.
    ///
    /// One predicate across the whole span rather than the per-day queries
    /// the rest of this file makes: a quarter of days would be ninety
    /// round-trips to EventKit for a figure shown in a popover, and the
    /// per-day shape exists to clip meetings to a workday, which this
    /// doesn't do.
    ///
    /// Same exclusions as `meetingEvents(on:)` — all-day events and events
    /// marked free are blocked-out time, not meetings attended — so the
    /// hours here agree with the hours on the bars.
    func attendedMeetings(from start: Date, to end: Date) -> [MeetingCost.Occurrence] {
        let scope = scopedCalendars()
        if let scope, scope.isEmpty { return [] }
        guard start < end else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: scope)
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.availability != .free else { return nil }
            guard let eventStart = event.startDate, let eventEnd = event.endDate, eventStart < eventEnd else {
                return nil
            }
            return MeetingCost.Occurrence(
                title: event.title ?? "",
                start: eventStart,
                end: eventEnd,
                // The same flag the delete confirmation reads, and the
                // reason this feature needs no new data.
                isRecurring: event.hasRecurrenceRules
            )
        }
    }

    /// The addresses EventKit recognises as *you*, gathered from the
    /// attendee lists of the days given.
    ///
    /// Mail knows the addresses on its own accounts, which is most of the
    /// answer, but people are invited to meetings at addresses they don't
    /// collect mail for — an old work address, a personal one on a shared
    /// calendar. Every one of those would otherwise show up in the people
    /// strip as somebody you work with, which is a strange thing to be told
    /// about yourself.
    func currentUserAddresses(on days: [Date]) -> Set<String> {
        var found: Set<String> = []
        for day in days {
            for event in meetingEvents(on: day) {
                for attendee in event.attendees ?? [] where attendee.isCurrentUser {
                    if let person = Person(participant: attendee) {
                        found.insert(person.address)
                    }
                }
            }
        }
        return found
    }

    // MARK: - Busy time

    /// Everything already claiming time on these days, for planning around.
    ///
    /// Wider than `meetingEvents` on purpose. That one drops events marked
    /// free, because they aren't meetings you attended; here they very much
    /// count, since a block of focus time you set aside last week is time
    /// you have already promised yourself. All-day events are still
    /// excluded — "on leave" spanning a whole day would otherwise leave no
    /// slot anywhere, when what it actually means is a question for you
    /// rather than an obstacle for the planner.
    ///
    /// Reads every calendar regardless of the user's reading selection: the
    /// point is to avoid double-booking them, and a clash on the calendar
    /// they didn't pick is still a clash.
    func busyIntervals(on days: [Date]) -> [(start: Date, end: Date)] {
        let calendar = Calendar.current
        guard let first = days.min(), let last = days.max() else { return [] }
        let start = calendar.startOfDay(for: first)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else {
            return []
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay else { return nil }
            guard let eventStart = event.startDate, let eventEnd = event.endDate, eventStart < eventEnd else {
                return nil
            }
            return (eventStart, eventEnd)
        }
    }

    // MARK: - Writing focus blocks

    /// Puts a block of focus time in the calendar.
    ///
    /// One of the two things this app writes, the other being `delete`.
    /// Everything else it does with EventKit is reading, and it stays that
    /// way — nothing here *edits* an event, so an invitation's time, title
    /// or attendees can never be changed behind your back.
    ///
    /// **Marked as free, deliberately.** A block of your own focus time is
    /// not a meeting, and the app's own definition of a meeting is exactly
    /// "an event that isn't marked free" (see `meetingEvents`). Writing the
    /// block as free is therefore not a convention that has to be
    /// remembered anywhere else: the time is claimed in your diary, other
    /// people see it as taken when they look for a slot, and Equilibrium's
    /// meeting count doesn't move — which matters when the reason for
    /// blocking the time was to have fewer meetings.
    @discardableResult
    func createFocusBlock(title: String, start: Date, end: Date, notes: String?) -> Bool {
        guard start < end else { return false }
        guard let destination = writableCalendar() else { return false }

        let event = EKEvent(eventStore: store)
        event.calendar = destination
        event.title = title
        event.startDate = start
        event.endDate = end
        event.availability = .free
        event.notes = notes

        do {
            try store.save(event, span: .thisEvent, commit: true)
            return true
        } catch {
            return false
        }
    }

    /// Where a block goes: the calendar being read when it can be written
    /// to, so the block lands beside the meetings it was planned around,
    /// and otherwise whatever Calendar itself would have used.
    ///
    /// A chosen calendar can easily be read-only — a subscribed work
    /// calendar, a shared one you're only invited to — so it can't simply
    /// be assumed.
    private func writableCalendar() -> EKCalendar? {
        if let selectedIdentifier,
           let chosen = store.calendar(withIdentifier: selectedIdentifier),
           chosen.allowsContentModifications {
            return chosen
        }
        let fallback = store.defaultCalendarForNewEvents
        return (fallback?.allowsContentModifications ?? false) ? fallback : nil
    }

    // MARK: - Deleting an event

    /// How much of a repeating meeting a delete takes with it.
    ///
    /// A thin wrapper on `EKSpan` so nothing above this file imports
    /// EventKit — the same reason `SelectableCalendar` and `DayMeeting`
    /// exist. Two cases and not three, because EventKit offers no "every
    /// occurrence including the ones already past": Calendar's own menu
    /// says "Delete This Event" and "Delete All Future Events", and this
    /// is those.
    enum DeletionScope {
        case thisOccurrence
        case thisAndLater

        fileprivate var span: EKSpan {
            switch self {
            case .thisOccurrence: return .thisEvent
            case .thisAndLater: return .futureEvents
            }
        }
    }

    /// How an attempt to delete one meeting ended. Named cases rather than
    /// a `Bool`, for the reason `MailArchiveResult` has them: "that
    /// calendar can't be written to" and "Calendar refused" send you to
    /// completely different places, and a single false says neither.
    enum DeleteResult: Equatable {
        case deleted
        /// It isn't there any more — already deleted, or moved in Calendar
        /// while this panel was showing it.
        case notFound
        /// The event lives on a calendar you can only read: a subscribed
        /// feed, a shared calendar you're an invitee on. Worth saying
        /// rather than reporting a failure, because nothing you do in this
        /// app will ever make that one deletable.
        case readOnly
        case failed
    }

    /// Removes a meeting from the calendar.
    ///
    /// The second and last thing this app writes, and the only destructive
    /// one — which is why the popover that calls it asks twice.
    ///
    /// **It does not decline the invitation, and it can't.** EventKit has
    /// no RSVP anywhere in it: `EKParticipant.participantStatus` is
    /// read-only, and so is `participation status` in Calendar's own
    /// AppleScript dictionary, so there is no supported way for any app
    /// outside Calendar to answer an invitation. Sending the reply
    /// ourselves isn't open either — this app has no network entitlement
    /// and never sends mail. So deleting is deleting: the meeting leaves
    /// your diary and stops counting against your day, and whoever called
    /// it still has you down as coming. `MeetingActionPopover` says so on
    /// the confirmation, because a silent no-show is a worse outcome than
    /// a meeting left on the calendar.
    func delete(eventIdentifier: String, startingAt start: Date, scope: DeletionScope) -> DeleteResult {
        guard let event = occurrence(identifier: eventIdentifier, startingAt: start) else {
            return .notFound
        }
        guard event.calendar?.allowsContentModifications == true else { return .readOnly }
        do {
            try store.remove(event, span: scope.span, commit: true)
            return .deleted
        } catch {
            return .failed
        }
    }

    /// The one occurrence that was on screen, found by day and start time.
    ///
    /// Deliberately not `event(withIdentifier:)`. Every occurrence of a
    /// repeating meeting shares a single event identifier, and that call
    /// hands back the series — so deleting "just this one" from a Thursday
    /// standup would delete the Monday the series began on instead. A
    /// date-bounded query returns the detached occurrence objects, and
    /// matching the start time picks the right one out of them.
    ///
    /// The same query the rest of this class reads through, so a meeting
    /// the app never showed you (all-day, marked free, on a calendar you
    /// aren't reading) can't be deleted through it either.
    private func occurrence(identifier: String, startingAt start: Date) -> EKEvent? {
        meetingEvents(on: start).first { event in
            guard event.eventIdentifier == identifier, let eventStart = event.startDate else {
                return false
            }
            // Seconds, not equality: EventKit hands back dates rebuilt from
            // the recurrence rule, and a sub-second difference from the one
            // carried on the `DayMeeting` would silently match nothing.
            return abs(eventStart.timeIntervalSince(start)) < 1
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
                // Attendees are only populated on events that were actually
                // invitations; a note-to-self in your own calendar has none,
                // and reads correctly as a meeting with nobody else in it.
                let attendees = (event.attendees ?? []).filter { !$0.isCurrentUser }
                let organizer = event.organizer.flatMap(Person.init(participant:))
                return DayMeeting(
                    id: id,
                    title: title,
                    start: start,
                    end: end,
                    joinURL: MeetingLinks.joinURL(for: event),
                    eventIdentifier: event.eventIdentifier,
                    isRecurring: event.hasRecurrenceRules,
                    organizer: organizer,
                    participants: attendees
                        .compactMap(Person.init(participant:))
                        .filter { $0 != organizer }
                )
            }
            .sorted { $0.start < $1.start }
    }
}
