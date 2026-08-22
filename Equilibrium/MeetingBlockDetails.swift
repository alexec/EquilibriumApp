import Foundation

/// What a meeting capsule on the chart says when the pointer stops on it.
///
/// The chart's blocks are intervals and nothing else: `MeetingBlock` holds a
/// start, an end and a UUID, because overlapping and back-to-back events are
/// merged into one block before being stored and there is no single title
/// left to keep with it. The titles live on `DayMeeting`, read from EventKit
/// for the day panel. So a tooltip is assembled at render time by matching a
/// block's interval back to that day's events — nothing new on
/// `MeetingBlock`, nothing to migrate in `history.json`, and no EventKit
/// query per hover (the day's meetings come from the week the view model
/// already caches for the people strip).
///
/// A block that matches no event still gets a tooltip: days older than the
/// calendar's own retention have no events to match, and a refused calendar
/// permission leaves nothing to match against. Both fall back to the times
/// the block itself knows, which is still more than the capsule shows at
/// 14pt wide.
enum MeetingBlockDetails {
    /// How many titles a merged block spells out before it starts counting.
    /// A morning of back-to-back calls folds into one block, and listing
    /// eleven of them makes a tooltip taller than the chart — the same trade
    /// the meeting popover makes with a long attendee list.
    static let maximumListedTitles = 5

    /// The day's events this block overlaps, earliest first.
    ///
    /// Overlap rather than equality, because the block has usually been
    /// reshaped since it was built: `MeetingCalculator` clips each event to
    /// the worked span, so a meeting that began before you started work is
    /// drawn short, and merging means one block can answer to several
    /// events. Strict comparisons on both ends are what keep the meeting
    /// starting exactly where this block finishes out of it.
    static func overlapping(_ block: MeetingBlock, in meetings: [DayMeeting]) -> [DayMeeting] {
        meetings
            .filter { $0.start < block.end && $0.end > block.start }
            .sorted { $0.start < $1.start }
    }

    /// The tooltip for one block: the event's title, its real time range and
    /// how long it runs; or, for a block several events were merged into,
    /// the block's own span and the list of what's in it.
    ///
    /// The times shown for a single meeting are the *event's*, not the
    /// block's, so they match what the day panel lists — a 9–10 meeting on a
    /// day you started at half past reads "9:00 AM – 10:00 AM" even though
    /// its capsule is half that long. The clipped figure is the one thing
    /// here you can already see.
    static func tooltip(for block: MeetingBlock, in meetings: [DayMeeting]) -> String {
        let matches = overlapping(block, in: meetings)
        let blockSpan = span(from: block.start, to: block.end)

        guard let only = matches.first else { return blockSpan }

        if matches.count == 1 {
            var lines = [only.title, span(from: only.start, to: only.end)]
            // Only where the link names something: `MeetingLinks.joinURL`
            // falls back to whatever was in the event's URL field, and
            // "meeting-notes.example.com" is not a way to join a call.
            if let service = only.joinURL.flatMap(MeetingLinks.serviceName) {
                lines.append(service)
            }
            return lines.joined(separator: "\n")
        }

        var lines = ["\(matches.count) meetings · \(blockSpan)"]
        lines += matches.prefix(maximumListedTitles).map { meeting in
            "\(MeetingTimeFormat.compactTime(meeting.start))  \(meeting.title)"
        }
        if matches.count > maximumListedTitles {
            lines.append("+\(matches.count - maximumListedTitles) more")
        }
        return lines.joined(separator: "\n")
    }

    /// "9:00 AM – 9:30 AM · 30 min" — the range in the day panel's format,
    /// and the length of it, which a range makes you work out.
    private static func span(from start: Date, to end: Date) -> String {
        "\(MeetingTimeFormat.rangeLabel(start: start, end: end)) · \(durationLabel(from: start, to: end))"
    }

    /// "30 min", "1h", "1h 15m".
    ///
    /// Not `HoursFormat`, which rounds to the half hour: that's the right
    /// unit for a day's work and the wrong one for meetings, where the
    /// commonest length of all would come out as "½h".
    static func durationLabel(from start: Date, to end: Date) -> String {
        let minutes = max(0, Int((end.timeIntervalSince(start) / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
