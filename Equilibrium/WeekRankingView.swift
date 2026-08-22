import SwiftUI

/// Past weeks, heaviest first, with what you wrote in them beside the
/// hours.
///
/// A list rather than a chart, on purpose. An eight-week rolling average
/// used to run behind the bars and was dropped in the f9cf969 rework,
/// rightly: a smoothed line answers no question anyone actually asks. The
/// longitudinal question people do ask is whether the heavy weeks were
/// worth being heavy, and that one is answered by putting the hours next to
/// the words and letting them be read together.
///
/// A sheet rather than a fourth column: the window already holds an inbox,
/// a week and a day, and this is something you go and look at rather than
/// something you keep an eye on.
struct WeekRankingView: View {
    let summaries: [WeekRanking.WeekSummary]
    /// The heaviest-against-lightest sentence, when there are enough
    /// answered weeks for it to mean anything.
    let comparison: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let comparison {
                Text(comparison)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.06))
                    )
            }

            if summaries.isEmpty {
                Text("No finished weeks yet. This fills in as the app watches you work.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(summaries) { summary in
                            WeekRankingRow(summary: summary, heaviestHours: summaries.first?.hours ?? 0)
                            if summary.id != summaries.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 560)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Weeks by hours")
                    .font(.system(size: 15, weight: .semibold))
                Text("Heaviest first, with what you wrote in them.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.cancelAction)
        }
    }
}

/// One week: what it cost on the left, what you said about it on the right.
private struct WeekRankingRow: View {
    let summary: WeekRanking.WeekSummary
    /// The heaviest week in the list, so each row's bar is drawn against
    /// the same scale — the whole point being to see one week against the
    /// others rather than each on its own.
    let heaviestHours: Double

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(HoursFormat.string(summary.hours))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                bar
                Text(dateRange)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(load)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 128, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if let verdict = summary.review?.verdict {
                    Text(verdict.meaning)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                if let answer = trimmed(summary.review?.answer) {
                    Text(answer)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(summary.checkIns, id: \.day) { note in
                    // The day's own words, with the day in front of them:
                    // a Wednesday that read badly is a different fact from
                    // a Friday that did, and stripping the date would make
                    // a week's notes into one anonymous paragraph.
                    // `foregroundColor` rather than `foregroundStyle`:
                    // the Text-returning form of the latter is macOS 14,
                    // and this app runs on 13.
                    (Text(Self.weekday.string(from: note.day) + "  ")
                        .foregroundColor(.secondary)
                     + Text(note.text))
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !summary.hasWords {
                    // Said rather than left blank: an empty right-hand
                    // column looks like the app lost something, where in
                    // fact the week simply went unremarked.
                    Text("Nothing written this week.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    /// A plain proportional bar, not a chart: it exists so the eye can sort
    /// the column faster than it can read four numbers.
    private var bar: some View {
        GeometryReader { geo in
            let fraction = heaviestHours > 0 ? min(1, summary.hours / heaviestHours) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 4)
    }

    private var dateRange: String {
        guard let end = summary.end else { return Self.dayInYear.string(from: summary.start) }
        return "\(Self.dayShort.string(from: summary.start)) – \(Self.dayInYear.string(from: end))"
    }

    private var load: String {
        var parts = ["\(summary.daysWorked) day\(summary.daysWorked == 1 ? "" : "s")"]
        if summary.meetingHours >= 0.5 {
            parts.append("\(HoursFormat.string(summary.meetingHours)) meetings")
        }
        return parts.joined(separator: " · ")
    }

    private func trimmed(_ text: String?) -> String? {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static let dayShort: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()
    private static let dayInYear: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
}
