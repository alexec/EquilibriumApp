import EventKit
import Foundation

/// Turns a day's calendar events into merged `MeetingBlock`s, clipped to
/// the workday span.
enum MeetingCalculator {
    /// Merges overlapping/back-to-back event intervals and clips each to
    /// the worked span, returning one `MeetingBlock` per merged interval —
    /// each with a real start/end time, ready to draw and drag.
    static func mergedBlocks(from events: [EKEvent], clippedTo span: WorkdaySpan) -> [MeetingBlock] {
        let intervals = events.compactMap { event -> (start: Date, end: Date)? in
            guard let s = event.startDate, let e = event.endDate else { return nil }
            let clippedStart = max(s, span.start)
            let clippedEnd = min(e, span.end)
            guard clippedStart < clippedEnd else { return nil }
            return (clippedStart, clippedEnd)
        }.sorted { $0.start < $1.start }

        var merged: [(start: Date, end: Date)] = []
        for interval in intervals {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }

        return merged.map { MeetingBlock(start: $0.start, end: $0.end) }
    }
}
