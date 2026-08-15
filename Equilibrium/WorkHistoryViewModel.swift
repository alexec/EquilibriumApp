import Foundation
import Combine

@MainActor
final class WorkHistoryViewModel: ObservableObject {
    @Published var spansByDay: [String: WorkdaySpan] = [:]
    @Published var isLoading = false
    @Published var weeklyInsight: String?
    @Published var calendarAccessGranted: Bool = false

    private let store = WorkHistoryStore()
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

    private let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    private let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.timeZone = .current
        return formatter
    }()

    /// Requests calendar access and kicks off the first data refresh.
    func requestCalendarAccessAndRefresh() async {
        calendarAccessGranted = await CalendarStore.shared.requestAccess()
        refresh()
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

            // Live events from IOKit (always available, no FDA required).
            let liveEvents = self.liveEventStore.load()

            // Historical backfill from pmset (requires Full Disk Access;
            // returns [] gracefully when FDA is not granted).
            let pmsetEvents = WakeLogParser.fetchUserPowerEvents()

            // Merge both sources, preferring pmset timestamps when the same
            // physical event appears in both (they'll be within 60 s).
            let merged = Self.mergedEvents(live: liveEvents, pmset: pmsetEvents)
            let freshSpans = WorkdayCalculator.computeSpans(from: merged, calendar: Calendar.current)

            await MainActor.run { [weak self] in
                guard let self else { return }
                let today = self.dayKey(for: Date())
                let yesterday = self.dayKey(for: self.calendar.date(byAdding: .day, value: -1, to: Date())!)
                self.spansByDay = self.store.merge(freshSpans: freshSpans, today: today, yesterday: yesterday)
                self.isLoading = false
                WeeklySummaryNotifier.fireIfNeeded(store: self.store)
                self.refreshInsight()
            }

            // Annotate spans with meeting data when calendar access is available.
            if granted {
                await self.refreshMeetingData()
            }
        }
    }

    /// Regenerates the on-device natural-language weekly insight from the
    /// current week's spans. Silently does nothing if Foundation Models
    /// isn't available (older macOS, or Apple Intelligence not enabled) —
    /// this is a nice-to-have, never a blocking or errorful feature.
    func refreshInsight() {
        guard WeeklyInsightGenerator.isAvailable else {
            weeklyInsight = nil
            return
        }
        guard #available(macOS 26.0, *) else { return }

        let week = currentWeekDays()
        let today = calendar.startOfDay(for: Date())
        let daysWorked: [(weekday: String, hours: Double)] = week.compactMap { day in
            guard day <= today, let hours = span(for: day)?.effectiveHours, hours > 0 else { return nil }
            return (weekdayFormatter.string(from: day), hours)
        }
        let workedSoFar = week.reduce(0.0) { $0 + (span(for: $1)?.effectiveHours ?? 0) }
        let summary = WeeklyInsightGenerator.WeekSummary(
            todayWeekday: weekdayFormatter.string(from: today),
            daysWorked: daysWorked,
            workedSoFarHours: workedSoFar,
            targetHours: WorkloadRecommender.weeklyTargetHours,
            todaysRecommendedHours: recommendedHours(for: today)
        )

        Task {
            weeklyInsight = await WeeklyInsightGenerator.generateInsight(for: summary)
        }
    }

    /// Re-reads calendar events for all days that have a WorkdaySpan and
    /// updates each span's `meetingMinutes` / `longestFocusBlockMinutes`.
    @MainActor
    func refreshMeetingData() async {
        let currentSpans = spansByDay
        var updated = currentSpans

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        for (dayKey, span) in currentSpans {
            guard span.hours > 0, let date = formatter.date(from: dayKey) else { continue }
            let events = CalendarStore.shared.meetingEvents(on: date, span: span)
            let (meetingMinutes, longestFocus) = MeetingCalculator.compute(events: events, span: span)
            var annotated = span
            annotated.meetingMinutes = meetingMinutes
            annotated.longestFocusBlockMinutes = longestFocus
            updated[dayKey] = annotated
        }

        spansByDay = updated
        // Persist updated spans so meeting data survives across launches.
        store.save(updated)
    }

    /// Handles a live IOKit power event: persists it and triggers a refresh
    /// so the current-day bar updates immediately.
    private func handleLiveEvent(_ event: PowerEvent) {
        liveEventStore.append([event])
        refresh()
    }

    /// Combines IOKit live events with pmset events, deduplicating events
    /// of the same kind that fall within 60 seconds of each other.  pmset
    /// timestamps are preferred when a duplicate is detected.
    ///
    /// Deduplication runs in O(n+m): pmset events are bucketed by (kind,
    /// minute) so that each live event can be checked in O(1).
    nonisolated static func mergedEvents(live: [PowerEvent], pmset: [PowerEvent]) -> [PowerEvent] {
        // Build a set of (kind, minute-bucket) keys from pmset events.
        // Any live event whose minute-bucket matches is considered a duplicate.
        var pmsetBuckets = Set<String>()
        for event in pmset {
            let bucket = minuteBucket(event)
            // Cover the boundary: also register the adjacent minute so that
            // events separated by up to 60 s are caught even when they straddle
            // a minute boundary.
            pmsetBuckets.insert(bucket)
            let adjacentDate = event.date.addingTimeInterval(60)
            pmsetBuckets.insert(minuteBucket(PowerEvent(kind: event.kind, date: adjacentDate)))
        }

        var result = pmset
        for liveEvent in live {
            if !pmsetBuckets.contains(minuteBucket(liveEvent)) {
                result.append(liveEvent)
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    /// Returns a string key representing the event's kind and the minute it
    /// falls in, used for O(1) duplicate detection in `mergedEvents`.
    private nonisolated static func minuteBucket(_ event: PowerEvent) -> String {
        let minute = Int(event.date.timeIntervalSinceReferenceDate / 60)
        return "\(event.kind)-\(minute)"
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
        refreshInsight()
    }

    /// Sets a manual meeting/focus split for a day — from dragging the
    /// boundary on its bar — clamped to that day's effective (worked)
    /// minutes. Start/end/break are untouched and stay fully automatic.
    func setMeetingSplit(for date: Date, meetingMinutes: Int) {
        let key = dayKey(for: date)
        guard var span = spansByDay[key] else { return }
        let effectiveMinutes = max(Int(span.effectiveHours * 60.0), 0)
        span.manualMeetingMinutes = min(max(meetingMinutes, 0), effectiveMinutes)
        spansByDay[key] = span
        store.save(spansByDay)
    }

    /// Clears a manual meeting/focus split, reverting the day's display to
    /// the calendar-derived meeting time.
    func resetMeetingSplit(for date: Date) {
        let key = dayKey(for: date)
        guard var span = spansByDay[key] else { return }
        span.manualMeetingMinutes = nil
        spansByDay[key] = span
        store.save(spansByDay)
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

    /// Recommended hours to work on `date` toward a 40-hour week, or nil if
    /// `date` isn't a remaining, unworked weekday in the current week.
    func recommendedHours(for date: Date) -> Double? {
        WorkloadRecommender.recommendedHours(
            for: date,
            week: currentWeekDays(),
            today: calendar.startOfDay(for: Date()),
            hoursWorked: { [weak self] day in self?.span(for: day)?.effectiveHours ?? 0 },
            calendar: calendar
        )
    }

    /// Hours worked this week subtracted from the 40-hour weekly target.
    /// Positive means hours remain; negative means already over budget.
    func remainingWeeklyHours() -> Double {
        let week = currentWeekDays()
        let worked = week.reduce(0.0) { $0 + (span(for: $1)?.effectiveHours ?? 0) }
        return WorkloadRecommender.weeklyTargetHours - worked
    }
}

