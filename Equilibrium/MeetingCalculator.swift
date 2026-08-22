import EventKit
import Foundation

/// Turns a day's calendar events into merged `MeetingBlock`s.
enum MeetingCalculator {
    /// Merges overlapping/back-to-back event intervals (no clipping),
    /// returning one `MeetingBlock` per merged interval — used for future
    /// days that don't have a workday span yet, so meetings still show.
    static func mergedBlocks(from events: [EKEvent]) -> [MeetingBlock] {
        let intervals = events.compactMap { event -> (start: Date, end: Date)? in
            guard let s = event.startDate, let e = event.endDate, s < e else { return nil }
            return (s, e)
        }
        return merge(intervals)
    }

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
        }
        return merge(intervals)
    }

    /// Merges intervals the caller already holds, clipping to `span` when
    /// there is one.
    ///
    /// The two entry points above start from `EKEvent` because that's what
    /// a calendar read hands back. This one exists for meetings the app is
    /// already carrying as `DayMeeting` — filtering the bars to one
    /// person's meetings, where going back to EventKit for events we have
    /// in memory would be a query per day per click.
    static func mergedBlocks(fromIntervals intervals: [(start: Date, end: Date)], clippedTo span: WorkdaySpan?) -> [MeetingBlock] {
        let usable = intervals.compactMap { interval -> (start: Date, end: Date)? in
            guard let span, !span.shifts.isEmpty else {
                return interval.start < interval.end ? interval : nil
            }
            let clippedStart = max(interval.start, span.start)
            let clippedEnd = min(interval.end, span.end)
            guard clippedStart < clippedEnd else { return nil }
            return (clippedStart, clippedEnd)
        }
        return merge(usable)
    }

    private static func merge(_ intervals: [(start: Date, end: Date)]) -> [MeetingBlock] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }
        return merged.map { MeetingBlock(start: $0.start, end: $0.end) }
    }
}
