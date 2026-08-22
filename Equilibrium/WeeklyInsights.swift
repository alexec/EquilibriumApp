import Foundation

/// The burnout signals a week can be asked for: late nights, weekend days
/// worked, and how the median start time is drifting.
///
/// All three are read by `WeeklySummaryNotifier`, which is the only thing
/// that asks — it turns them into the Saturday digest's one sentence, and
/// owns the wording. This file deliberately returns numbers rather than
/// phrases: it used to also build a "1 late night · start drift ↑ · 1
/// weekend day" string for the week header, that header was replaced by the
/// hours sentence in f9cf969, and the string builder sat here uncalled for
/// long enough to be filed as a bug (#72). Numbers are harder to strand,
/// because the caller has to say something with them.
enum WeeklyInsights {

    // MARK: - Late nights

    /// The hour at or after which finishing work counts as a "late night".
    ///
    /// One value, because the digest previously carried its own copy of
    /// this — set to 20 while the constant here said 22, so the app held two
    /// answers to "was that a late night" and showed you the other one. 20
    /// is what the digest has always counted, and so is what survived.
    static let defaultLateNightHour: Int = 20

    /// Number of days in `week` where the work end-time falls at or after
    /// `lateNightHour` o'clock (local time).
    static func lateNightCount(
        spans: [WorkdaySpan?],
        lateNightHour: Int = defaultLateNightHour,
        calendar: Calendar = .current
    ) -> Int {
        spans.compactMap { $0 }.filter { span in
            guard !span.shifts.isEmpty else { return false }
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

    /// How much later the median start has to be before it's worth
    /// mentioning, in hours. Half an hour: a week's medians move by a few
    /// minutes on their own, and a signal that fires every week is one
    /// nobody reads.
    static let defaultStartDriftThreshold: Double = 0.5

    /// Median start hour (fractional, e.g. 9.5 = 09:30) across the non-zero
    /// working days in a week's spans, or nil if there are no working days.
    static func medianStartHour(
        spans: [WorkdaySpan?],
        calendar: Calendar = .current
    ) -> Double? {
        let hours: [Double] = spans.compactMap { span -> Double? in
            guard let span, !span.shifts.isEmpty else { return nil }
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

    /// How many minutes later `spans` starts than `previous`, or nil when
    /// either week has no working days or the difference is under
    /// `threshold`. Only later counts: starting earlier than last week is
    /// not a thing the digest needs to wake anyone up about.
    ///
    /// Rounded to five minutes. The median of a handful of wake times isn't
    /// accurate to the minute, and "43 min later" claims a precision this
    /// doesn't have.
    static func startDriftMinutes(
        spans: [WorkdaySpan?],
        previous: [WorkdaySpan?],
        threshold: Double = defaultStartDriftThreshold,
        calendar: Calendar = .current
    ) -> Int? {
        guard let current = medianStartHour(spans: spans, calendar: calendar),
              let earlier = medianStartHour(spans: previous, calendar: calendar) else { return nil }
        let drift = current - earlier
        guard drift >= threshold else { return nil }
        return Int((drift * 60 / 5).rounded()) * 5
    }
}
