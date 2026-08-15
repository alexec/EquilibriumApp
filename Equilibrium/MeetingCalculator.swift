import EventKit
import Foundation

/// Computes meeting time and longest focus (meeting-free) block from a list
/// of calendar events and the WorkdaySpan they fall within.
enum MeetingCalculator {

    /// Returns the total meeting minutes and the longest contiguous
    /// meeting-free block (in minutes) within the worked span.
    ///
    /// Overlapping meetings are merged before summing. Focus blocks are
    /// the gaps between merged meeting intervals within `span.start…span.end`.
    static func compute(events: [EKEvent], span: WorkdaySpan) -> (meetingMinutes: Int, longestFocusBlockMinutes: Int) {
        let merged = mergedIntervals(from: events, clippedTo: span)

        let totalMeetingSeconds = merged.reduce(0.0) { acc, interval in
            acc + interval.end.timeIntervalSince(interval.start)
        }
        let meetingMinutes = Int(totalMeetingSeconds / 60.0)

        let longestFocus = longestFocusBlock(mergedMeetings: merged, span: span)
        return (meetingMinutes, longestFocus)
    }

    // MARK: - Private Helpers

    /// Merges overlapping event intervals, clipping each to the worked span.
    private static func mergedIntervals(from events: [EKEvent], clippedTo span: WorkdaySpan) -> [(start: Date, end: Date)] {
        let intervals = events.compactMap { event -> (start: Date, end: Date)? in
            guard let s = event.startDate, let e = event.endDate else { return nil }
            let clippedStart = max(s, span.start)
            let clippedEnd = min(e, span.end)
            guard clippedStart < clippedEnd else { return nil }
            return (clippedStart, clippedEnd)
        }.sorted { $0.start < $1.start }

        var merged: [(start: Date, end: Date)] = []
        for interval in intervals {
            if var last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = (last.start, max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// Returns the length (in minutes) of the longest gap between merged
    /// meeting blocks (or the full span if there are no meetings).
    private static func longestFocusBlock(mergedMeetings: [(start: Date, end: Date)], span: WorkdaySpan) -> Int {
        var gapStart = span.start
        var longestSeconds: TimeInterval = 0

        for meeting in mergedMeetings {
            let gap = meeting.start.timeIntervalSince(gapStart)
            if gap > longestSeconds { longestSeconds = gap }
            gapStart = meeting.end
        }
        // Final gap after last meeting
        let trailingGap = span.end.timeIntervalSince(gapStart)
        if trailingGap > longestSeconds { longestSeconds = trailingGap }

        return Int(longestSeconds / 60.0)
    }
}
