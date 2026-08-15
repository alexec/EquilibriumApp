import Foundation
import Combine

@MainActor
final class WorkHistoryViewModel: ObservableObject {
    @Published var spansByDay: [String: WorkdaySpan] = [:]
    @Published var isLoading = false
    @Published var calendarAccessGranted: Bool = false

    private let store = WorkHistoryStore()
    private let calendar: Calendar = .current
    private var autoRefreshTimer: Timer?

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

    /// Starts a repeating timer that keeps today's bar current while the app
    /// is open, since refresh() otherwise only ever runs once on appear.
    func startAutoRefresh() {
        guard autoRefreshTimer == nil else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.autoRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
    }

    func refresh() {
        spansByDay = store.load()
        isLoading = true
        let granted = calendarAccessGranted
        Task.detached(priority: .userInitiated) {
            let events = WakeLogParser.fetchUserPowerEvents()
            let freshSpans = WorkdayCalculator.computeSpans(from: events, calendar: Calendar.current)

            await MainActor.run {
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

