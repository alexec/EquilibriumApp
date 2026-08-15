import Foundation
import Combine

@MainActor
final class WorkHistoryViewModel: ObservableObject {
    @Published var spansByDay: [String: WorkdaySpan] = [:]
    @Published var isLoading = false
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
            }

            // Annotate spans with meeting data when calendar access is available.
            if granted {
                await self.refreshMeetingData()
            }
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

    /// Manually sets (or overwrites) the given day's worked hours as a
    /// permanent override that automatic refreshes will never replace.
    /// Times and break duration are clipped to the nearest 30-minute mark.
    func setManualHours(for date: Date, start: Date, end: Date, breakMinutes: Int) {
        let span = WorkdaySpan(
            dayKey: dayKey(for: date),
            start: TimeRounding.roundedToNearestHalfHour(start),
            end: TimeRounding.roundedToNearestHalfHour(end),
            breakMinutes: breakMinutes,
            isManual: true
        )
        spansByDay = store.setManualSpan(span)
    }

    /// Permanently blanks out a day's hours (0h), protected like any other
    /// manual override so automatic refreshes never repopulate it.
    func deleteHours(for date: Date) {
        let span = WorkdaySpan(dayKey: dayKey(for: date), start: date, end: date, isManual: true)
        spansByDay = store.setManualSpan(span)
    }

    /// Clears a manual override for the given day.
    func clearManualHours(for date: Date) {
        spansByDay = store.clearManualSpan(dayKey: dayKey(for: date))
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

    /// Average hours/weekday across a set of days: sum of all hours worked
    /// (any day) divided by the number of weekdays that have any recorded
    /// data, so incomplete weeks and weekend work don't skew the figure.
    func averageHours(for days: [Date]) -> Double {
        let total = days.reduce(0.0) { $0 + (span(for: $1)?.effectiveHours ?? 0) }

        let weekdaysWithData = days.filter { day in
            guard let span = span(for: day), span.hours > 0 else { return false }
            return !WeekCalendar.isWeekend(day, calendar: calendar)
        }.count

        guard weekdaysWithData > 0 else { return 0 }
        return total / Double(weekdaysWithData)
    }

    /// Rolling mean of effective hours/weekday over the most recent `weeks`
    /// complete weeks (excluding the current, in-progress week). Only
    /// weekdays that have any recorded data are included in the denominator,
    /// so sparse history doesn't artificially deflate the average.
    func rollingAverageHoursPerDay(weeks: Int = 8) -> Double {
        // Current week days are excluded so the baseline is not influenced
        // by the week the user is comparing against.
        let currentWeek = Set(currentWeekDays().map { dayKey(for: $0) })
        let windowDays = rollingWindowDays(weeks: weeks)
            .filter { !currentWeek.contains(dayKey(for: $0)) }
        return averageHours(for: windowDays)
    }

    /// A one-line insight comparing this week's total against the 8-week
    /// rolling average, e.g. "This week: 43h — 12% above your 8-week avg."
    /// Returns nil when there is not enough history to produce a meaningful
    /// comparison (baseline average is zero).
    var rollingAverageInsight: String? {
        let weekDays = currentWeekDays()
        let thisWeekTotal = weekDays.reduce(0.0) { $0 + (span(for: $1)?.effectiveHours ?? 0) }

        // Only weekdays with data contribute to the denominator.
        let weekdaysWithData = weekDays.filter { day in
            guard let s = span(for: day), s.hours > 0 else { return false }
            return !WeekCalendar.isWeekend(day, calendar: calendar)
        }.count
        guard weekdaysWithData > 0 else { return nil }

        let baseline = rollingAverageHoursPerDay(weeks: 8)
        guard baseline > 0 else { return nil }

        // Express this week in weekly hours by scaling the per-day average.
        let baselineWeekly = baseline * 5
        let diff = ((thisWeekTotal - baselineWeekly) / baselineWeekly * 100).rounded()
        let sign = diff >= 0 ? "+" : ""
        return "This week: \(Int(thisWeekTotal.rounded(.up)))h — \(sign)\(Int(diff))% vs your 8-week avg (\(Int(baselineWeekly.rounded()))h)"
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

    /// Meeting percentage (0–100) across a set of days, or nil when no
    /// calendar data is available for any day with hours.
    func meetingPercentage(for days: [Date]) -> Double? {
        var totalEffectiveMinutes = 0
        var totalMeetingMinutes = 0
        var hasCalendarData = false

        for day in days {
            guard let span = span(for: day), span.hours > 0 else { continue }
            guard let meeting = span.meetingMinutes else { continue }
            hasCalendarData = true
            totalEffectiveMinutes += Int(span.effectiveHours * 60.0)
            totalMeetingMinutes += meeting
        }

        guard hasCalendarData, totalEffectiveMinutes > 0 else { return nil }
        return Double(totalMeetingMinutes) / Double(totalEffectiveMinutes) * 100.0
    }
}

