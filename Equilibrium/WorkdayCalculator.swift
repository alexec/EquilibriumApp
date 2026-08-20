import Foundation

/// Groups wake events into workdays, and each workday into shifts. A new
/// day starts when the gap since the previous wake is >= 8 hours; otherwise
/// the wake extends the current day.  A day's end is the sleep event that
/// immediately follows its last wake (when the machine actually went to
/// sleep), falling back to the last wake itself if no such sleep was logged.
///
/// Within a day, a sleep/wake gap of `shiftGapThreshold` or more ends one
/// shift and starts the next — that's lunch, or the break before an evening
/// stint. Shorter gaps (>= `intraBreakThreshold`) are too brief to be a
/// shift boundary and are summed into `WorkdaySpan.intraBreakMinutes`
/// instead, still deducted but without pretending to split the day. The
/// longest uninterrupted active stretch and whether a proper lunch break was
/// taken are also computed and stored on the day.
enum WorkdayCalculator {
    static let gapThreshold: TimeInterval = 8 * 3600

    /// Minimum sleep/wake gap counted as an intra-day break (20 minutes).
    static let intraBreakThreshold: TimeInterval = 20 * 60

    /// Minimum gap counted as a "real" lunch/rest break (30 minutes).
    static let lunchBreakThreshold: TimeInterval = 30 * 60

    /// Minimum gap that ends a shift and begins another (45 minutes). Above
    /// the length of a long coffee and below a real lunch: a break that
    /// splits the day into two shifts should be one you actually went
    /// somewhere for, not every time the screen locked itself.
    static let shiftGapThreshold: TimeInterval = 45 * 60

    static func computeSpans(from events: [PowerEvent], calendar: Calendar = .current) -> [WorkdaySpan] {
        let wakes = events.filter { $0.kind == .wake }.map(\.date).sorted()
        let sleeps = events.filter { $0.kind == .sleep }.map(\.date).sorted()

        guard var blockStart = wakes.first else { return [] }
        var lastWake = blockStart
        var previous = blockStart

        // Break accumulator for gaps too short to split a shift.
        var intraBreakSeconds: TimeInterval = 0
        var intraBreakHasLunch = false
        // Gaps (active stretches) for longest-stretch calculation.
        var stretchStart = blockStart    // start of current active stretch
        var longestStretchSeconds: TimeInterval = 0
        // Shifts closed so far today, and where the open one began.
        var segments: [WorkShift] = []
        var segmentStart = blockStart

        var spans: [WorkdaySpan] = []

        func flush(before boundary: Date?) {
            let candidateSleep = sleeps.first { sleep in
                sleep > lastWake && (boundary.map { sleep < $0 } ?? true)
            }
            let end = candidateSleep ?? lastWake

            // Close out the final active stretch (from last wake to end).
            let finalStretch = end.timeIntervalSince(stretchStart)
            if finalStretch > longestStretchSeconds {
                longestStretchSeconds = finalStretch
            }
            if end > segmentStart {
                segments.append(WorkShift(start: segmentStart, end: end))
            }

            // A day that ended up with more stretches than a day is allowed
            // to hold gives its narrowest gaps back as deducted break time.
            let (shifts, absorbedMinutes) = ShiftPlan.normalize(segments)
            let breakMins = Int((intraBreakSeconds / 60).rounded()) + absorbedMinutes
            let longestMins = Int((longestStretchSeconds / 60).rounded())

            spans.append(WorkdaySpan(
                dayKey: dayKey(for: blockStart, calendar: calendar),
                shifts: shifts,
                intraBreakMinutes: breakMins,
                longestStretchMinutes: longestMins,
                hasLunchBreak: intraBreakHasLunch
            ))
        }

        func resetBlock(from wake: Date) {
            blockStart = wake
            lastWake = wake
            previous = wake
            intraBreakSeconds = 0
            intraBreakHasLunch = false
            stretchStart = wake
            longestStretchSeconds = 0
            segments = []
            segmentStart = wake
        }

        for wake in wakes.dropFirst() {
            let gap = wake.timeIntervalSince(previous)
            if gap >= gapThreshold {
                flush(before: wake)
                resetBlock(from: wake)
            } else if gap >= intraBreakThreshold {
                // Find the sleep event that ended the previous active stretch,
                // so we measure only the actual idle/sleep interval (sleep→wake)
                // rather than the full wake→wake gap which includes active time.
                let breakDuration: TimeInterval
                let stretchEnd: Date
                if let sleepBeforeWake = sleeps.last(where: { $0 > previous && $0 < wake }) {
                    breakDuration = wake.timeIntervalSince(sleepBeforeWake)
                    // Active stretch ended at the sleep event, not at the previous wake.
                    stretchEnd = sleepBeforeWake
                } else {
                    // No sleep event logged; fall back to the full wake-to-wake gap.
                    breakDuration = gap
                    stretchEnd = previous
                }
                let stretchLen = stretchEnd.timeIntervalSince(stretchStart)
                if stretchLen > longestStretchSeconds {
                    longestStretchSeconds = stretchLen
                }
                if breakDuration >= intraBreakThreshold {
                    if breakDuration >= lunchBreakThreshold {
                        intraBreakHasLunch = true
                    }
                    if breakDuration >= shiftGapThreshold {
                        // Long enough to be a break you went somewhere for:
                        // the shift ends here and the next one starts on the
                        // other side of it.
                        if stretchEnd > segmentStart {
                            segments.append(WorkShift(start: segmentStart, end: stretchEnd))
                        }
                        segmentStart = wake
                    } else {
                        intraBreakSeconds += breakDuration
                    }
                }
                stretchStart = wake
                lastWake = wake
                previous = wake
            } else {
                lastWake = wake
                previous = wake
            }
        }
        flush(before: nil)

        return spans
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }
}
