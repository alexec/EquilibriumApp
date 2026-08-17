import Foundation
import Combine

/// Which daily-intention sheet the main window should present, if any.
enum DailyPromptKind: Equatable {
    case intention
    case checkIn
}

@MainActor
final class WorkHistoryViewModel: ObservableObject {
    @Published var spansByDay: [String: WorkdaySpan] = [:]
    @Published var isLoading = false
    @Published var calendarAccessGranted: Bool = false
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
    /// When set, the main window presents the matching intention / check-in sheet.
    @Published var presentedDailyPrompt: DailyPromptKind?
    /// Calendars offered by the preferences picker. Empty until calendar
    /// access is granted, since EventKit vends nothing before then.
    @Published var availableCalendars: [SelectableCalendar] = []
    /// Which calendar is read, or `nil` while the user hasn't picked one.
    @Published var calendarSelection: String?

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
        intentionsByDay = intentionStore.load()
        calendarSelection = CalendarStore.shared.selection
    }

    /// The `WeekHeaderStats` each week's summary was last generated from,
    /// so an unchanged week doesn't re-invoke the model on every refresh.
    private var lastWeekHeaderStats: [String: WeeklyInsightGenerator.WeekHeaderStats] = [:]

    private let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    /// Requests calendar access and kicks off the first data refresh.
    func requestCalendarAccessAndRefresh() async {
        calendarAccessGranted = await CalendarStore.shared.requestAccess()
        if calendarAccessGranted {
            availableCalendars = CalendarStore.shared.availableCalendars()
        }
        refresh()
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
                DailyIntentionNotifier.reschedule(preferences: self.preferences)
                self.refreshWeekHeaderSummaries()
            }

            // Annotate spans with meeting data when calendar access is available.
            if granted {
                await self.refreshMeetingData()
            }
        }
    }

    /// Regenerates the LLM "You worked ..." caption for each week currently
    /// shown in the chart (mirrors `DailyBarChartView`'s own 7-day grouping
    /// of the same rolling window). Skips any week whose `WeekHeaderStats`
    /// haven't changed since the last generation, so an unchanged week
    /// doesn't re-invoke the model on every 5-minute auto-refresh. Silently
    /// does nothing if Foundation Models isn't available.
    func refreshWeekHeaderSummaries() {
        guard WeeklyInsightGenerator.isAvailable else { return }
        guard #available(macOS 26.0, *) else { return }

        let days = rollingWindowDays(weeks: 2)
        for weekStart in stride(from: 0, to: days.count, by: 7) {
            let week = Array(days[weekStart..<min(weekStart + 7, days.count)])
            guard let first = week.first else { continue }
            let key = dayKey(for: first)

            guard let stats = WeeklyInsightGenerator.WeekHeaderStats.compute(
                from: week.map { span(for: $0) },
                weeklyTargetHours: preferences.weeklyTargetHours
            ) else {
                lastWeekHeaderStats[key] = nil
                weekHeaderSummaries[key] = nil
                continue
            }
            guard lastWeekHeaderStats[key] != stats else { continue }
            lastWeekHeaderStats[key] = stats

            Task {
                weekHeaderSummaries[key] = await WeeklyInsightGenerator.generateWeekHeaderSummary(for: stats)
            }
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

    /// A rolling window of full Sat-Fri weeks ending with the current week
    /// (including its future days), covering `weeks` weeks total. Weeks
    /// start on Saturday (European style): Sat, Sun, Mon, Tue, Wed, Thu, Fri.
    func rollingWindowDays(weeks: Int) -> [Date] {
        WeekCalendar.rollingWindowDays(weeks: weeks, calendar: calendar)
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

    func todayIntention() -> DailyIntention? {
        intentionsByDay[dayKey(for: Date())]
    }

    /// Today's calendar meetings with titles, for the intention / check-in lists.
    func todayMeetings() -> [DayMeeting] {
        guard calendarAccessGranted else { return [] }
        return CalendarStore.shared.dayMeetings(on: Date())
    }

    func saveIntention(goals: String, outcomes: String) {
        let key = dayKey(for: Date())
        var entry = intentionsByDay[key] ?? DailyIntention(dayKey: key)
        entry.goals = goals
        entry.outcomes = outcomes
        entry.intentionSetAt = Date()
        intentionsByDay = intentionStore.upsert(entry)
        presentedDailyPrompt = nil
    }

    func saveCheckIn(reflection: String) {
        let key = dayKey(for: Date())
        var entry = intentionsByDay[key] ?? DailyIntention(dayKey: key)
        entry.checkInReflection = reflection
        entry.checkedInAt = Date()
        intentionsByDay = intentionStore.upsert(entry)
        presentedDailyPrompt = nil
    }

    /// Opens the intention or check-in sheet (from menu bar / notification tap).
    func presentDailyPrompt(_ kind: DailyPromptKind) {
        presentedDailyPrompt = kind
    }

    func dismissDailyPrompt() {
        presentedDailyPrompt = nil
    }

    /// Handles a tap on a daily-intention notification (`userInfo` action).
    func handleNotificationAction(_ action: String?) {
        switch action {
        case "intention":
            presentedDailyPrompt = .intention
        case "checkIn":
            presentedDailyPrompt = .checkIn
        default:
            break
        }
    }
}

