import Foundation

/// Groups wake events into contiguous workday blocks. A new block starts
/// when the gap since the previous wake is >= 8 hours; otherwise the wake
/// extends the current block. A block's end time is the sleep event that
/// immediately follows its last wake (when the machine actually went to
/// sleep), falling back to the last wake itself if no such sleep was logged.
///
/// Intra-day gaps: sleep/wake pairs whose gap is >= `intraBreakThreshold`
/// but < `gapThreshold` are treated as breaks within the same workday and
/// summed into `WorkdaySpan.intraBreakMinutes`. The longest uninterrupted
/// active stretch and whether a proper lunch break was taken are also
/// computed and stored on the span.
enum WorkdayCalculator {
    static let gapThreshold: TimeInterval = 8 * 3600

    /// Minimum sleep/wake gap counted as an intra-day break (20 minutes).
    static let intraBreakThreshold: TimeInterval = 20 * 60

    /// Minimum gap counted as a "real" lunch/rest break (30 minutes).
    static let lunchBreakThreshold: TimeInterval = 30 * 60

    static func computeSpans(from events: [PowerEvent], calendar: Calendar = .current) -> [WorkdaySpan] {
        let wakes = events.filter { $0.kind == .wake }.map(\.date).sorted()
        let sleeps = events.filter { $0.kind == .sleep }.map(\.date).sorted()

        guard var blockStart = wakes.first else { return [] }
        var lastWake = blockStart
        var previous = blockStart

        // Intra-day break accumulator for the current block.
        var intraBreakSeconds: TimeInterval = 0
        var intraBreakHasLunch = false
        // Gaps (active stretches) for longest-stretch calculation.
        var stretchStart = blockStart    // start of current active stretch
        var longestStretchSeconds: TimeInterval = 0

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

            let breakMins = Int((intraBreakSeconds / 60).rounded())
            let longestMins = Int((longestStretchSeconds / 60).rounded())

            spans.append(WorkdaySpan(
                dayKey: dayKey(for: blockStart, calendar: calendar),
                start: blockStart,
                end: end,
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
                if let sleepBeforeWake = sleeps.last(where: { $0 > previous && $0 < wake }) {
                    breakDuration = wake.timeIntervalSince(sleepBeforeWake)
                    // Active stretch ended at the sleep event, not at the previous wake.
                    let stretchLen = sleepBeforeWake.timeIntervalSince(stretchStart)
                    if stretchLen > longestStretchSeconds {
                        longestStretchSeconds = stretchLen
                    }
                } else {
                    // No sleep event logged; fall back to the full wake-to-wake gap.
                    breakDuration = gap
                    let stretchLen = previous.timeIntervalSince(stretchStart)
                    if stretchLen > longestStretchSeconds {
                        longestStretchSeconds = stretchLen
                    }
                }
                if breakDuration >= intraBreakThreshold {
                    intraBreakSeconds += breakDuration
                    if breakDuration >= lunchBreakThreshold {
                        intraBreakHasLunch = true
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
