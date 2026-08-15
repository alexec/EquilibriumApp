import Foundation

/// Derives human-readable burnout-signal strings from a single week's
/// worth of workday spans and their corresponding calendar dates.
enum WeeklyInsights {

    // MARK: - Late nights

    /// The default threshold hour (22:00) after which a day is considered
    /// a "late night."
    static let defaultLateNightHour: Int = 22

    /// Number of days in `week` where the work end-time falls at or after
    /// `lateNightHour` o'clock (local time).
    static func lateNightCount(
        spans: [WorkdaySpan?],
        lateNightHour: Int = defaultLateNightHour,
        calendar: Calendar = .current
    ) -> Int {
        spans.compactMap { $0 }.filter { span in
            guard span.hours > 0 else { return false }
            let hour = calendar.component(.hour, from: span.end)
            return hour >= lateNightHour
        }.count
    }

    // MARK: - Weekend work

    /// Number of weekend days (Saturday or Sunday) in `days` that have
    /// recorded work (effectiveHours > 0).
    static func weekendWorkCount(
        days: [Date],
        spans: [WorkdaySpan?],
        calendar: Calendar = .current
    ) -> Int {
        zip(days, spans).filter { day, span in
            WeekCalendar.isWeekend(day, calendar: calendar) &&
            (span?.effectiveHours ?? 0) > 0
        }.count
    }

    // MARK: - Start-time drift

    /// Median start hour (fractional, e.g. 9.5 = 09:30) across the non-zero
    /// working days in a week's spans, or nil if there are no working days.
    static func medianStartHour(
        spans: [WorkdaySpan?],
        calendar: Calendar = .current
    ) -> Double? {
        let hours: [Double] = spans.compactMap { span -> Double? in
            guard let span, span.hours > 0 else { return nil }
            let comps = calendar.dateComponents([.hour, .minute], from: span.start)
            guard let h = comps.hour, let m = comps.minute else { return nil }
            return Double(h) + Double(m) / 60.0
        }.sorted()
        guard !hours.isEmpty else { return nil }
        let mid = hours.count / 2
        if hours.count.isMultiple(of: 2) {
            return (hours[mid - 1] + hours[mid]) / 2.0
        }
        return hours[mid]
    }

    // MARK: - Narrative strings

    /// Returns a short narrative string for the given week, or nil if there
    /// is nothing noteworthy to report.
    ///
    /// - Parameters:
    ///   - days:              The 7 calendar dates in this week.
    ///   - spans:             Corresponding optional spans (parallel to `days`).
    ///   - previousMedianStart: Median start hour of the preceding week, used
    ///                        to detect start-time drift; pass nil when there
    ///                        is no prior week.
    ///   - driftThreshold:   How many minutes later the median must be before
    ///                       flagging drift (default: 30 min).
    ///   - lateNightHour:    Hour at which a work-end counts as a late night.
    static func narrative(
        days: [Date],
        spans: [WorkdaySpan?],
        previousMedianStart: Double?,
        driftThreshold: Double = 0.5,
        lateNightHour: Int = defaultLateNightHour,
        calendar: Calendar = .current
    ) -> String? {
        var parts: [String] = []

        let lateNights = lateNightCount(spans: spans, lateNightHour: lateNightHour, calendar: calendar)
        if lateNights > 0 {
            parts.append(lateNights == 1 ? "1 late night" : "\(lateNights) late nights")
        }

        if let prev = previousMedianStart,
           let curr = medianStartHour(spans: spans, calendar: calendar),
           curr - prev >= driftThreshold {
            parts.append("start drift ↑")
        }

        let weekendDays = weekendWorkCount(days: days, spans: spans, calendar: calendar)
        if weekendDays > 0 {
            parts.append(weekendDays == 1 ? "1 weekend day" : "\(weekendDays) weekend days")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
