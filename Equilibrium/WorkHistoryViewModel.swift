import Foundation
import Combine

@MainActor
final class WorkHistoryViewModel: ObservableObject {
    @Published var spansByDay: [String: WorkdaySpan] = [:]
    @Published var isLoading = false
    @Published var weeklyInsight: String?

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

    private let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.timeZone = .current
        return formatter
    }()

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
        Task.detached(priority: .userInitiated) {
            let events = WakeLogParser.fetchUserPowerEvents()
            let freshSpans = WorkdayCalculator.computeSpans(from: events, calendar: Calendar.current)

            await MainActor.run {
                let today = self.dayKey(for: Date())
                let yesterday = self.dayKey(for: self.calendar.date(byAdding: .day, value: -1, to: Date())!)
                self.spansByDay = self.store.merge(freshSpans: freshSpans, today: today, yesterday: yesterday)
                self.isLoading = false
                self.refreshInsight()
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
        refreshInsight()
    }

    /// Permanently blanks out a day's hours (0h), protected like any other
    /// manual override so automatic refreshes never repopulate it.
    func deleteHours(for date: Date) {
        let span = WorkdaySpan(dayKey: dayKey(for: date), start: date, end: date, isManual: true)
        spansByDay = store.setManualSpan(span)
        refreshInsight()
    }

    /// Clears a manual override for the given day.
    func clearManualHours(for date: Date) {
        spansByDay = store.clearManualSpan(dayKey: dayKey(for: date))
        refreshInsight()
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
}
