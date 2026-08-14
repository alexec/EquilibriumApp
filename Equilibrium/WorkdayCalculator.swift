import Foundation

/// Groups wake events into contiguous workday blocks. A new block starts
/// when the gap since the previous wake is >= 8 hours; otherwise the wake
/// extends the current block. A block's end time is the sleep event that
/// immediately follows its last wake (when the machine actually went to
/// sleep), falling back to the last wake itself if no such sleep was logged.
enum WorkdayCalculator {
    static let gapThreshold: TimeInterval = 8 * 3600

    static func computeSpans(from events: [PowerEvent], calendar: Calendar = .current) -> [WorkdaySpan] {
        let wakes = events.filter { $0.kind == .wake }.map(\.date).sorted()
        let sleeps = events.filter { $0.kind == .sleep }.map(\.date).sorted()

        guard var blockStart = wakes.first else { return [] }
        var lastWake = blockStart
        var previous = blockStart

        var spans: [WorkdaySpan] = []

        func flush(before boundary: Date?) {
            let candidateSleep = sleeps.first { sleep in
                sleep > lastWake && (boundary.map { sleep < $0 } ?? true)
            }
            let end = candidateSleep ?? lastWake
            spans.append(WorkdaySpan(dayKey: dayKey(for: blockStart, calendar: calendar), start: blockStart, end: end))
        }

        for wake in wakes.dropFirst() {
            let gap = wake.timeIntervalSince(previous)
            if gap >= gapThreshold {
                flush(before: wake)
                blockStart = wake
            }
            lastWake = wake
            previous = wake
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
