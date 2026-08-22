import Foundation

/// What a repeating meeting has actually cost, over a span long enough to
/// be worth deciding about.
///
/// Of everything this app measures, meetings are the one lever anyone
/// really controls: you can't decide to need less sleep or to have fewer
/// emails arrive, but you can leave a standing meeting. That decision is
/// far easier against "this has taken 14h since May" than against a vague
/// sense that there are a lot of them.
///
/// Read-only arithmetic over events the calendar already holds. It suggests
/// nothing, and in particular it never suggests declining: this app cannot
/// RSVP and says so wherever the question comes up.
enum MeetingCost {

    /// One attended occurrence, flattened out of EventKit so the sums here
    /// can be checked without a calendar.
    struct Occurrence: Equatable {
        let title: String
        let start: Date
        let end: Date
        let isRecurring: Bool

        var hours: Double { max(0, end.timeIntervalSince(start)) / 3600.0 }
    }

    /// A repeating meeting and what it has come to.
    struct Series: Identifiable, Equatable {
        /// The title as it appears in the diary, from the most recent
        /// occurrence: a meeting renamed mid-quarter is one meeting, and
        /// the name it has now is the one you'd recognise.
        let title: String
        let occurrences: Int
        let hours: Double
        /// The first and last occurrence counted, so a row can say what
        /// span the figure covers rather than implying it's for all time.
        let first: Date
        let last: Date

        var id: String { key }
        /// Grouping key: the title with case and surrounding space
        /// ignored, since "Standup" and "standup " are the same meeting to
        /// everyone but a string comparison.
        var key: String { MeetingCost.key(for: title) }
    }

    static func key(for title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Every repeating meeting in `occurrences`, dearest first.
    ///
    /// Only repeating ones. A one-off that happened once is not a cost you
    /// can do anything about, and listing it beside a standing meeting
    /// would bury the thing worth seeing. A series that has met once so far
    /// is included: it repeats, so it will go on costing, and that is the
    /// moment the figure is most useful.
    static func series(in occurrences: [Occurrence]) -> [Series] {
        let repeating = occurrences.filter { $0.isRecurring && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let grouped = Dictionary(grouping: repeating) { key(for: $0.title) }

        return grouped.values.compactMap { group -> Series? in
            let sorted = group.sorted { $0.start < $1.start }
            guard let first = sorted.first, let last = sorted.last else { return nil }
            return Series(
                title: last.title.trimmingCharacters(in: .whitespacesAndNewlines),
                occurrences: sorted.count,
                hours: sorted.reduce(0) { $0 + $1.hours },
                first: first.start,
                last: last.end
            )
        }
        .sorted { lhs, rhs in
            lhs.hours == rhs.hours ? lhs.title < rhs.title : lhs.hours > rhs.hours
        }
    }

    /// What one meeting's series has cost, or nil when this meeting doesn't
    /// repeat — the popover asks this way, holding one meeting and wanting
    /// its history.
    static func series(matching title: String, in occurrences: [Occurrence]) -> Series? {
        series(in: occurrences).first { $0.key == key(for: title) }
    }
}
