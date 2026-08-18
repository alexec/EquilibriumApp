import Foundation
import Combine

/// The two things recorded against a day: a morning intention and an
/// end-of-day check-in.
enum DailyPromptKind: Equatable {
    case intention
    case checkIn
}

/// How far the calendar permission has got. `pending` covers both "not
/// asked yet" and "prompt still on screen": from the app's side they're the
/// same wait, and both end when `requestAccess()` returns.
enum CalendarAccessState: Equatable {
    case pending
    case granted
    case denied
}

/// The day the side panel is editing, and which of its two sections asked
/// to be edited — the panel always shows both, so the kind only decides
/// where the keyboard focus lands.
struct DayEditorSelection: Equatable {
    let day: Date
    var kind: DailyPromptKind
}

@MainActor
final class WorkHistoryViewModel: ObservableObject {
    @Published var spansByDay: [String: WorkdaySpan] = [:]
    @Published var isLoading = false
    /// Where calendar access has got to. Three states rather than a flag
    /// because "not granted" covers two situations the UI shouldn't
    /// conflate: still waiting on the prompt, and told no.
    @Published var calendarAccess: CalendarAccessState = .pending
    /// Whether meetings can be read right now — the question most of this
    /// class asks, with the reason it can't left to the UI.
    var calendarAccessGranted: Bool { calendarAccess == .granted }
    /// LLM-generated "You worked ..." caption per week, keyed by that
    /// week's first day (`dayKey`). Falls back to a deterministic sentence
    /// (see `WeeklyInsightGenerator.WeekHeaderStats.fallbackSentence`)
    /// wherever a key is missing — model unavailable, or not generated yet.
    @Published var weekHeaderSummaries: [String: String] = [:]
    /// The user's configured work schedule — weekly target, workday span,
    /// and (optionally) meeting/focus targets. Set manually or parsed from
    /// free text via `WorkPreferencesGenerator`; see `PreferencesView`.
    @Published var preferences: WorkPreferences = WorkPreferencesStore.load()
    /// Per-day morning intentions + evening check-ins.
    @Published var intentionsByDay: [String: DailyIntention] = [:]
    /// LLM phrase describing a day's meetings, keyed by `dayKey`. Missing
    /// wherever the model is unavailable or hasn't answered yet — the panel
    /// shows the count and hours regardless.
    @Published var meetingGists: [String: String] = [:]
    /// The day shown in the panel beside the chart. Always set — the panel
    /// is permanent furniture rather than something you open — so this
    /// starts on today and only ever moves to another day.
    @Published var dayEditor = DayEditorSelection(day: Calendar.current.startOfDay(for: Date()), kind: .intention)
    /// Calendars offered by the preferences picker. Empty until calendar
    /// access is granted, since EventKit vends nothing before then.
    @Published var availableCalendars: [SelectableCalendar] = []
    /// Which calendar is read, or `nil` while the user hasn't picked one.
    @Published var calendarSelection: String?
    /// Which week the chart shows, counted from the current one: 0 is this
    /// week, -1 last week. The chart is deliberately one week at a time —
    /// the week is the unit everything else here works in (the target, the
    /// recommendation, the weekly summary) — so history is reached by
    /// paging rather than by widening the window.
    @Published private(set) var weekOffset: Int = 0

    private let store = WorkHistoryStore()
    private let intentionStore = DailyIntentionStore()
    private let liveEventStore = LiveEventStore()
    private let calendar: Calendar = .current
    private var autoRefreshTimer: Timer?
    private lazy var powerMonitor: PowerNotificationMonitor = {
        PowerNotificationMonitor { [weak self] event in
            Task { @MainActor in
                self?.handleLiveEvent(event)
            }
        }
    }()

    private static let autoRefreshInterval: TimeInterval = 5 * 60

    init() {
        // Both stores are read here so the first paint already has the
        // week's bars and its intentions. The refresh that follows sits
        // behind `await CalendarStore.requestAccess()`, which can take
        // seconds — or, seen in practice, not come back at all — and
        // loading only there left the chart looking like a machine with no
        // history rather than one waiting on a permission.
        spansByDay = store.load()
        intentionsByDay = intentionStore.load()
        calendarSelection = CalendarStore.shared.selection
    }

    /// The `WeekHeaderStats` each week's summary was last generated from,
    /// so an unchanged week doesn't re-invoke the model on every refresh.
    private var lastWeekHeaderStats: [String: WeeklyInsightGenerator.WeekHeaderStats] = [:]
    /// The meetings each day's gist was generated from, same idea.
    private var lastGistMeetings: [String: String] = [:]

    private let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    /// Requests calendar access and kicks off the first data refresh.
    func requestCalendarAccessAndRefresh() async {
        calendarAccess = await CalendarStore.shared.requestAccess() ? .granted : .denied
        if calendarAccessGranted {
            availableCalendars = CalendarStore.shared.availableCalendars()
        }
        refresh()
        // The day the panel opens on never goes through `selectDay`, and
        // until access resolves there are no meetings to describe anyway —
        // so this is the first moment today's summary can be asked for.
        refreshMeetingGist()
    }

    /// Records a new calendar choice and re-reads meeting data so days
    /// annotated from a no-longer-selected calendar drop their meetings
    /// immediately, rather than lingering until the next auto-refresh.
    func updateCalendarSelection(_ identifier: String?) {
        CalendarStore.shared.updateSelection(identifier)
        calendarSelection = identifier
        guard calendarAccessGranted else { return }
        Task { await refreshMeetingData() }
    }

    /// Starts IOKit power-notification monitoring and the periodic refresh
    /// timer.  Safe to call more than once.
    func startAutoRefresh() {
        powerMonitor.start()
        guard autoRefreshTimer == nil else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.autoRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopAutoRefresh() {
        powerMonitor.stop()
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    func refresh() {
        spansByDay = store.load()
        isLoading = true
        // Captured before entering the detached task: reading the @Published
        // property from off the main actor would be a data race.
        let granted = calendarAccessGranted
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Live events captured by IOKit and persisted across launches.
            // This is the only wake/sleep source: the sandbox rules out
            // shelling out to `pmset -g log` for historical backfill.
            let liveEvents = self.liveEventStore.load()
            let freshSpans = WorkdayCalculator.computeSpans(from: liveEvents, calendar: Calendar.current)

            await MainActor.run { [weak self] in
                guard let self else { return }
                let today = self.dayKey(for: Date())
                let yesterday = self.dayKey(for: self.calendar.date(byAdding: .day, value: -1, to: Date())!)
                self.spansByDay = self.store.merge(freshSpans: freshSpans, today: today, yesterday: yesterday)
                self.isLoading = false
                WeeklySummaryNotifier.fireIfNeeded(store: self.store, weeklyTargetHours: self.preferences.weeklyTargetHours)
                self.refreshWeekHeaderSummaries()
            }

            // Annotate spans with meeting data when calendar access is available.
            if granted {
                await self.refreshMeetingData()
            }
        }
    }

    /// Regenerates the LLM "You worked ..." caption for the week the chart
    /// is currently showing. Skips the work when that week's
    /// `WeekHeaderStats` haven't changed since the last generation, so an
    /// unchanged week doesn't re-invoke the model on every 5-minute auto
    /// refresh — and so paging back and forth through weeks reuses what's
    /// already been generated rather than asking again. Silently does
    /// nothing if Foundation Models isn't available.
    func refreshWeekHeaderSummaries() {
        guard WeeklyInsightGenerator.isAvailable else { return }
        guard #available(macOS 26.0, *) else { return }

        let week = visibleWeekDays
        guard let first = week.first else { return }
        let key = dayKey(for: first)

        guard let stats = WeeklyInsightGenerator.WeekHeaderStats.compute(
            from: week.map { span(for: $0) },
            weeklyTargetHours: preferences.weeklyTargetHours
        ) else {
            lastWeekHeaderStats[key] = nil
            weekHeaderSummaries[key] = nil
            return
        }
        guard lastWeekHeaderStats[key] != stats else { return }
        lastWeekHeaderStats[key] = stats

        Task {
            let summary = await WeeklyInsightGenerator.generateWeekHeaderSummary(for: stats)
            // Generation takes seconds, and the week's figures can change
            // while it runs — an edited day, an auto-refresh. If they have,
            // a newer generation is already under way and this sentence
            // describes numbers the bars no longer show, so it's dropped
            // rather than left on screen until the figures next change.
            guard lastWeekHeaderStats[key] == stats else { return }
            weekHeaderSummaries[key] = summary
        }
    }

    /// The LLM-generated caption for the week starting on `day`, or nil if
    /// unavailable/not yet generated — callers should fall back to
    /// `WeeklyInsightGenerator.WeekHeaderStats.fallbackSentence`.
    func weekHeaderSummary(forWeekStarting day: Date) -> String? {
        weekHeaderSummaries[dayKey(for: day)]
    }

    /// Re-reads calendar events for every stored day (clipped to the workday
    /// span when there is one, full-day otherwise) and for remaining days in
    /// the current week, so future days without a work capsule still show
    /// meetings. Days with hand-dragged meetings (`meetingsManuallyEdited`)
    /// are left alone — see `updateMeeting`.
    ///
    /// Zero-hour days are re-read too, not just worked ones. They can hold
    /// meetings (a day full of calls but no tracked activity), and if they
    /// were skipped their meetings would be frozen forever — most visibly
    /// after deselecting a calendar in preferences, where its events would
    /// linger on exactly those days.
    @MainActor
    func refreshMeetingData() async {
        var updated = spansByDay
        let today = calendar.startOfDay(for: Date())

        for (key, span) in spansByDay {
            guard !span.meetingsManuallyEdited else { continue }
            guard let date = dayKeyFormatter.date(from: key) else { continue }

            // Clip to the workday only when one was actually tracked;
            // a zero-hour day would clip every meeting away to nothing.
            let hasWorkday = span.hours > 0
            let events = hasWorkday
                ? CalendarStore.shared.meetingEvents(on: date, span: span)
                : CalendarStore.shared.meetingEvents(on: date)
            let meetings = hasWorkday
                ? MeetingCalculator.mergedBlocks(from: events, clippedTo: span)
                : MeetingCalculator.mergedBlocks(from: events)

            // A zero-hour day whose meetings have all gone carries nothing
            // worth keeping, so drop the row rather than leaving an empty
            // placeholder bar. Manual overrides are the exception: the user
            // put that day there deliberately.
            //
            // Only today onward, matching the current-week pass below.
            // Nothing ever re-scans a past date that isn't already stored,
            // so dropping one would be permanent — re-selecting a calendar
            // in preferences could never bring that day back. Past days keep
            // their (now empty) row instead, which renders the same as no row.
            if meetings.isEmpty, !hasWorkday, !span.isManual, date >= today {
                updated.removeValue(forKey: key)
                continue
            }

            var annotated = span
            annotated.meetings = meetings
            annotated.hasCalendarData = true
            updated[key] = annotated
        }

        // Current week from today onward: always surface calendar meetings,
        // even when there's no workday yet (start == end → 0h placeholder).
        for date in currentWeekDays() where date >= today {
            let key = dayKey(for: date)
            if let existing = updated[key], existing.hours > 0 { continue }
            if let existing = updated[key], existing.meetingsManuallyEdited { continue }

            let events = CalendarStore.shared.meetingEvents(on: date)
            let meetings = MeetingCalculator.mergedBlocks(from: events)
            // Don't invent empty history rows for days with nothing on the
            // calendar; drop a prior 0h holder once its meetings clear.
            if meetings.isEmpty {
                if let existing = updated[key], existing.hours == 0, !existing.isManual {
                    updated.removeValue(forKey: key)
                }
                continue
            }

            var span = updated[key] ?? WorkdaySpan(dayKey: key, start: date, end: date)
            span.meetings = meetings
            span.hasCalendarData = true
            updated[key] = span
        }

        spansByDay = updated
        // Persist updated spans so meeting data survives across launches.
        store.save(updated)
        // Meeting data just landed, which affects what the week summaries
        // describe — refresh those that changed.
        refreshWeekHeaderSummaries()
        refreshMeetingGist()
    }

    /// Drag-clamp bounds for a meeting: the workday when one exists,
    /// otherwise the chart's 6am–midnight window for that calendar day.
    private func meetingClampBounds(for span: WorkdaySpan, on date: Date) -> (Date, Date) {
        if span.hours > 0 {
            return (span.start, span.end)
        }
        let startOfDay = calendar.startOfDay(for: date)
        let start = calendar.date(
            bySettingHour: Int(ChartScale.startHour), minute: 0, second: 0, of: startOfDay
        ) ?? startOfDay
        let end = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        return (start, end)
    }

    /// Handles a live IOKit power event: persists it and triggers a refresh
    /// so the current-day bar updates immediately.
    private func handleLiveEvent(_ event: PowerEvent) {
        liveEventStore.append([event])
        refresh()
    }

    private func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    func span(for date: Date) -> WorkdaySpan? {
        spansByDay[dayKey(for: date)]
    }

    /// Permanently blanks out a day's hours (0h), protected like any other
    /// manual override so automatic refreshes never repopulate it.
    func deleteHours(for date: Date) {
        let span = WorkdaySpan(dayKey: dayKey(for: date), start: date, end: date, isManual: true)
        spansByDay = store.setManualSpan(span)
        refreshWeekHeaderSummaries()
    }

    /// Creates or edits a day's workday span — from dragging its top edge
    /// (start), bottom edge (end), or middle (move) on the day bar, or
    /// drawing a brand-new one on a day with no data yet. Marks the day
    /// `isManual` (the same flag that already protects hand-set spans from
    /// automatic wake/sleep recompute) so this sticks. Existing meetings/
    /// break data on the day are preserved; if calendar access is granted
    /// and the day's meetings haven't been hand-edited, they're refetched
    /// immediately against the new span rather than waiting for the next
    /// auto-refresh.
    func updateWorkday(for date: Date, newStart: Date, newEnd: Date) {
        let key = dayKey(for: date)
        var span = spansByDay[key] ?? WorkdaySpan(dayKey: key, start: newStart, end: newEnd)
        span.start = newStart
        span.end = newEnd
        if calendarAccessGranted, !span.meetingsManuallyEdited {
            let events = CalendarStore.shared.meetingEvents(on: date, span: span)
            span.meetings = MeetingCalculator.mergedBlocks(from: events, clippedTo: span)
            span.hasCalendarData = true
        }
        spansByDay = store.setManualSpan(span)
        refreshWeekHeaderSummaries()
    }

    /// Updates one meeting's start/end — from dragging its top edge, bottom
    /// edge, or body on the day bar — clamped within that day's workday, or
    /// the chart window when there's no workday yet. Marks the day
    /// `meetingsManuallyEdited` so the next calendar refresh doesn't
    /// overwrite the edit. Start/end/break are untouched.
    func updateMeeting(for date: Date, meetingID: UUID, newStart: Date, newEnd: Date) {
        let key = dayKey(for: date)
        guard var span = spansByDay[key] else { return }
        guard let index = span.meetings.firstIndex(where: { $0.id == meetingID }) else { return }

        let (boundStart, boundEnd) = meetingClampBounds(for: span, on: date)
        let clampedStart = min(max(newStart, boundStart), boundEnd)
        let clampedEnd = min(max(newEnd, boundStart), boundEnd)
        guard clampedStart < clampedEnd else { return }

        span.meetings[index].start = clampedStart
        span.meetings[index].end = clampedEnd
        span.meetingsManuallyEdited = true
        spansByDay[key] = span
        store.save(spansByDay)
        refreshWeekHeaderSummaries()
    }

    /// Clears manual meeting edits for a day and immediately re-fetches
    /// from the calendar, reverting to calendar-derived meeting blocks.
    func resetMeetings(for date: Date) {
        let key = dayKey(for: date)
        guard var span = spansByDay[key] else { return }
        span.meetingsManuallyEdited = false
        if span.hours > 0 {
            let events = CalendarStore.shared.meetingEvents(on: date, span: span)
            span.meetings = MeetingCalculator.mergedBlocks(from: events, clippedTo: span)
        } else {
            let events = CalendarStore.shared.meetingEvents(on: date)
            span.meetings = MeetingCalculator.mergedBlocks(from: events)
        }
        span.hasCalendarData = true
        spansByDay[key] = span
        store.save(spansByDay)
        refreshWeekHeaderSummaries()
    }

    /// The week the chart is showing: a full Sat-Fri range (European-style
    /// weeks: Sat, Sun, Mon, Tue, Wed, Thu, Fri), including future days.
    var visibleWeekDays: [Date] {
        WeekCalendar.weekDays(offset: weekOffset, calendar: calendar)
    }

    /// How a week is named in the chart's navigation: the two most recent
    /// weeks get a relative name, since that's how you'd refer to them;
    /// older ones get their date range.
    ///
    /// Takes the week rather than deriving its own, so the name always
    /// describes the bars actually on screen. Deriving it here would mean a
    /// second reading of "now", which around midnight can land in a
    /// different week from the one the chart drew.
    func weekLabel(for week: [Date]) -> String {
        switch weekOffset {
        case 0: return "This week"
        case -1: return "Last week"
        default:
            guard let first = week.first, let last = week.last else { return "" }
            let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
            let end = sameMonth ? Self.dayOnlyFormatter : Self.monthDayFormatter
            return "\(Self.monthDayFormatter.string(from: first)) – \(end.string(from: last))"
        }
    }

    // Built once and reused: SwiftUI reads `weekLabel(for:)` on every pass
    // over the chart's body, and a DateFormatter is expensive enough that
    // constructing two per read is worth avoiding. Confined to the main
    // actor with the rest of the class, so sharing them is safe.
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let dayOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    /// Paging back stops at the week holding the oldest day on record —
    /// there's nothing before it but empty charts.
    var canShowPreviousWeek: Bool {
        guard let earliest = spansByDay.keys.min(), let earliestDay = dayKeyFormatter.date(from: earliest) else {
            return false
        }
        return earliestDay < WeekCalendar.weekStart(offset: weekOffset, calendar: calendar)
    }

    /// Paging forward stops at the current week; there's no data ahead of it.
    var canShowNextWeek: Bool { weekOffset < 0 }

    func showPreviousWeek() {
        guard canShowPreviousWeek else { return }
        weekOffset -= 1
        moveSelectionWithWeek(days: -7)
        refreshWeekHeaderSummaries()
    }

    func showNextWeek() {
        guard canShowNextWeek else { return }
        weekOffset += 1
        moveSelectionWithWeek(days: 7)
        refreshWeekHeaderSummaries()
    }

    /// Keeps the panel on the week the chart is showing, landing on the same
    /// weekday: paging back from Monday shows the Monday before it. Without
    /// this the panel would sit on a day that isn't among the bars beside
    /// it, its highlighted column nowhere on screen.
    private func moveSelectionWithWeek(days: Int) {
        guard let moved = calendar.date(byAdding: .day, value: days, to: dayEditor.day) else { return }
        // Paging forward can land past today, which has no check-in to make;
        // the panel handles that by hiding the section, so only the day moves.
        dayEditor = DayEditorSelection(day: moved, kind: dayEditor.kind)
    }

    /// This week's full Saturday-through-Friday range, including future days.
    func currentWeekDays() -> [Date] {
        WeekCalendar.currentWeekDays(calendar: calendar)
    }

    /// Recommended hours to work on `date` toward the configured weekly
    /// target, or nil if `date` isn't a remaining, unworked weekday in the
    /// current week.
    func recommendedHours(for date: Date) -> Double? {
        WorkloadRecommender.recommendedHours(
            for: date,
            week: currentWeekDays(),
            today: calendar.startOfDay(for: Date()),
            weeklyTargetHours: preferences.weeklyTargetHours,
            hoursWorked: { [weak self] day in self?.span(for: day)?.effectiveHours ?? 0 },
            calendar: calendar
        )
    }

    /// Hours still to work today: what's left of the week's target, spread
    /// over the weekdays still to come, today included. It falls as the day
    /// is worked, reaches zero once the week's budget is spent, and asks for
    /// nothing at the weekend.
    ///
    /// Deliberately not `WorkloadRecommender.recommendedHours(for:)`, which
    /// answers a different question — what an untouched day should hold —
    /// and stops answering at all once a day has any hours on it. The menu
    /// bar needs a figure that counts down while you work.
    func remainingHoursToday() -> Double {
        let today = calendar.startOfDay(for: Date())
        guard !WeekCalendar.isWeekend(today, calendar: calendar) else { return 0 }

        let week = currentWeekDays()
        let worked = week.reduce(0.0) { $0 + (span(for: $1)?.effectiveHours ?? 0) }
        let remainingBudget = preferences.weeklyTargetHours - worked
        guard remainingBudget > 0 else { return 0 }

        let daysLeft = week.filter {
            !WeekCalendar.isWeekend($0, calendar: calendar) && $0 >= today
        }.count
        guard daysLeft > 0 else { return 0 }

        return remainingBudget / Double(daysLeft)
    }

    /// Hours worked this week subtracted from the configured weekly target.
    /// Positive means hours remain; negative means already over budget.
    func remainingWeeklyHours() -> Double {
        let week = currentWeekDays()
        let worked = week.reduce(0.0) { $0 + (span(for: $1)?.effectiveHours ?? 0) }
        return preferences.weeklyTargetHours - worked
    }

    /// Updates and persists the user's work-schedule preferences.
    func updatePreferences(_ new: WorkPreferences) {
        preferences = new
        WorkPreferencesStore.save(new)
        DailyIntentionNotifier.reschedule(preferences: new)
    }

    // MARK: - Daily intention / check-in

    /// A day's intention / check-in, for any day — the chart's buttons and
    /// the panel both work on whichever day you click, not just today.
    func intention(for day: Date) -> DailyIntention? {
        intentionsByDay[dayKey(for: day)]
    }

    /// A day's calendar meetings with titles, for the panel's list. Past
    /// days work as well as today: EventKit keeps the events, so a day
    /// being edited weeks later still shows what was in the diary.
    func meetings(for day: Date) -> [DayMeeting] {
        guard calendarAccessGranted else { return [] }
        return CalendarStore.shared.dayMeetings(on: day)
    }

    /// Writes a day's intention and check-in together, since the panel
    /// edits both at once.
    ///
    /// The two timestamps record when each was *first* set, so editing an
    /// old day's wording doesn't restamp it as though it were written
    /// today; clearing the text back to empty drops the timestamp, which is
    /// what returns the day's button to its unfilled state.
    func saveDayEntry(day: Date, goals: String, outcomes: String, reflection: String) {
        let key = dayKey(for: day)
        let existing = intentionsByDay[key]

        // Opening a day and moving on without typing shouldn't leave a
        // record behind. With auto-save, closing the panel always writes,
        // so without this every day merely glanced at would be stored as an
        // empty entry.
        let isBlank = (goals + outcomes + reflection).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard existing != nil || !isBlank else { return }

        var entry = existing ?? DailyIntention(dayKey: key)
        entry.goals = goals
        entry.outcomes = outcomes
        entry.checkInReflection = reflection

        let hasIntentionText = !(goals + outcomes).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        entry.intentionSetAt = hasIntentionText ? (entry.intentionSetAt ?? Date()) : nil
        let hasReflection = !reflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        entry.checkedInAt = hasReflection ? (entry.checkedInAt ?? Date()) : nil

        // Auto-save fires on every close as well as on a debounce, so most
        // calls have nothing new in them; rewriting the file anyway would be
        // churn for no change.
        guard entry != existing else { return }
        intentionsByDay = intentionStore.upsert(entry)
    }

    /// Points the panel at `day`, focused on one of its two sections.
    func selectDay(_ day: Date, kind: DailyPromptKind) {
        dayEditor = DayEditorSelection(day: calendar.startOfDay(for: day), kind: kind)
        refreshMeetingGist()
    }

    /// Asks the on-device model for a phrase describing the panel's day.
    ///
    /// Tracked against the meetings it was generated from rather than
    /// generated once per day: choosing a different calendar, editing an
    /// event, or today simply gaining another meeting all change the list,
    /// and a phrase describing meetings that are no longer shown is worse
    /// than none. Unchanged lists don't ask the model again.
    func refreshMeetingGist() {
        guard MeetingSummaryGenerator.isAvailable else { return }
        guard #available(macOS 26.0, *) else { return }

        let day = dayEditor.day
        let key = dayKey(for: day)
        let meetings = meetings(for: day)
        guard meetings.count > 1 else {
            // A day whose meetings have gone — a different calendar chosen,
            // an event deleted — shouldn't keep a phrase describing the ones
            // it used to have.
            meetingGists[key] = nil
            lastGistMeetings[key] = nil
            return
        }

        let signature = meetings
            .map { "\($0.id)|\($0.start.timeIntervalSinceReferenceDate)|\($0.end.timeIntervalSinceReferenceDate)|\($0.title)" }
            .joined(separator: "\n")
        guard lastGistMeetings[key] != signature else { return }
        lastGistMeetings[key] = signature

        Task { @MainActor in
            let gist = await MeetingSummaryGenerator.generateGist(for: meetings)
            // The day's meetings can change again while the model is
            // thinking, in which case a second generation is already under
            // way and this answer describes a list nobody is looking at.
            guard lastGistMeetings[key] == signature else { return }
            // Assigned even when nothing comes back, which clears the key:
            // the signature has been recorded, so nothing will ask again for
            // this list, and keeping the old phrase would leave it sitting
            // under meetings it no longer describes.
            meetingGists[key] = gist
        }
    }

    /// The phrase for a day's meetings, or nil while there isn't one.
    func meetingGist(for day: Date) -> String? {
        meetingGists[dayKey(for: day)]
    }

    /// Points the panel at today (from the menu bar or a notification tap).
    func presentDailyPrompt(_ kind: DailyPromptKind) {
        selectDay(Date(), kind: kind)
    }

    /// Handles a tap on a daily-intention notification (`userInfo` action).
    func handleNotificationAction(_ action: String?) {
        switch action {
        case "intention":
            presentDailyPrompt(.intention)
        case "checkIn":
            presentDailyPrompt(.checkIn)
        default:
            break
        }
    }
}

