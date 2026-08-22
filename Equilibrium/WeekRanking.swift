import Foundation

/// Past weeks, heaviest first, each carrying what you wrote during it.
///
/// This is the app's thesis stated as a view. It has always known the hours
/// precisely and has never once put them next to an outcome — so a 44-hour
/// week and a 34-hour week have been indistinguishable in everything but
/// size. Ranked side by side with your own words in them, they either read
/// differently or they don't, and if they don't, the extra ten hours bought
/// nothing.
///
/// Pure, and separate from the view that draws it, so the arithmetic can be
/// checked without a window (there is no test target; see `CLAUDE.md`).
enum WeekRanking {

    /// One week's row: what it cost, and what you said about it.
    struct WeekSummary: Identifiable, Equatable {
        /// The `dayKey` of the week's Saturday — the same key
        /// `WeeklyReview` is stored under.
        let weekKey: String
        let start: Date
        let days: [Date]
        /// Worked hours, breaks already out (`effectiveHours`).
        let hours: Double
        /// Hours of that spent in meetings.
        let meetingHours: Double
        /// Days with any hours on them at all.
        let daysWorked: Int
        /// The answer to "was that worth it?", where one was given.
        let review: WeeklyReview?
        /// What was written at the end of the days in this week, in the
        /// order they happened.
        let checkIns: [DayNote]

        var id: String { weekKey }

        var end: Date? { days.last }

        /// Whether this week says anything back — a verdict, a weekly
        /// sentence, or a day's check-in. A week with hours and no words is
        /// the common case and still belongs in the list; this is what the
        /// comparison at the top counts.
        var hasWords: Bool {
            review?.hasAnswer == true || !checkIns.isEmpty
        }
    }

    /// One day's check-in, kept with its date so a row can say which day
    /// the words came from.
    struct DayNote: Equatable {
        let day: Date
        let text: String
    }

    /// Every week with hours on it, heaviest first.
    ///
    /// Ties break towards the recent week, so two identical weeks read in
    /// the order they'd be remembered in. Weeks with no tracked hours are
    /// left out entirely: a week the machine was off for isn't a light
    /// week, it's an absence, and ranking it as the best week of the year
    /// would be the single most misleading thing this list could do.
    static func summaries(
        spans: [String: WorkdaySpan],
        intentions: [String: DailyIntention],
        reviews: [String: WeeklyReview],
        calendar: Calendar = .current,
        today: Date = Date()
    ) -> [WeekSummary] {
        let formatter = dayKeyFormatter(calendar: calendar)
        let currentWeekStart = WeekCalendar.weekStart(calendar: calendar, today: today)

        // Group the stored days into the weeks they belong to, so the list
        // covers exactly the history on disk without anyone having to say
        // how far back to look.
        var weekStarts: Set<Date> = []
        for key in spans.keys {
            guard let day = formatter.date(from: key) else { continue }
            let start = WeekCalendar.weekStart(calendar: calendar, today: day)
            // The week being lived is on the chart, and its hours aren't
            // final until Friday; ranking it against finished weeks would
            // put it near the bottom every Monday.
            guard start < currentWeekStart else { continue }
            weekStarts.insert(start)
        }

        return weekStarts.map { start -> WeekSummary in
            let days = WeekCalendar.weekDays(calendar: calendar, today: start)
            let keys = days.map { formatter.string(from: $0) }
            let weekSpans = keys.compactMap { spans[$0] }

            let checkIns: [DayNote] = zip(days, keys).compactMap { day, key in
                let text = intentions[key]?.checkInReflection
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return text.isEmpty ? nil : DayNote(day: day, text: text)
            }

            return WeekSummary(
                weekKey: formatter.string(from: start),
                start: start,
                days: days,
                hours: weekSpans.reduce(0) { $0 + $1.effectiveHours },
                meetingHours: weekSpans.reduce(0) { $0 + Double($1.meetingMinutes) / 60.0 },
                daysWorked: weekSpans.filter { $0.effectiveHours > 0 }.count,
                review: reviews[formatter.string(from: start)],
                checkIns: checkIns
            )
        }
        .filter { $0.hours > 0 }
        .sorted { lhs, rhs in
            lhs.hours == rhs.hours ? lhs.start > rhs.start : lhs.hours > rhs.hours
        }
    }

    /// The sentence at the top: the heaviest weeks against the lightest,
    /// answered in your own verdicts.
    ///
    /// This is the only claim in the app that touches the question the
    /// README opens with, so it is deliberately arithmetic and deliberately
    /// cautious. It compares the top third with the bottom third, states
    /// both averages, and says how many weeks in each you called worth it.
    /// It draws no conclusion — if the heavy weeks bought something, that
    /// shows in the counts, and if they didn't, that shows too. Telling
    /// someone what their own answers mean is a step this app doesn't get
    /// to take.
    ///
    /// Nil until there are enough answered weeks for the comparison to be
    /// anything but noise: with three answers, one changed mind rewrites
    /// the sentence.
    static func comparison(_ summaries: [WeekSummary], minimumAnswered: Int = 6) -> String? {
        let answered = summaries.filter { $0.review?.verdict != nil }
        guard answered.count >= minimumAnswered else { return nil }

        let third = max(1, answered.count / 3)
        let heaviest = Array(answered.prefix(third))
        let lightest = Array(answered.suffix(third))

        let heavyHours = average(heaviest.map(\.hours))
        let lightHours = average(lightest.map(\.hours))
        // A comparison of two figures that round to the same thing isn't
        // one. Better to say nothing than to dress a flat year as a finding.
        guard HoursFormat.string(heavyHours) != HoursFormat.string(lightHours) else { return nil }

        let heavyWorth = heaviest.filter { $0.review?.verdict == .worthIt }.count
        let lightWorth = lightest.filter { $0.review?.verdict == .worthIt }.count
        let noun = third == 1 ? "week" : "weeks"

        return "Your \(third) heaviest \(noun) averaged \(HoursFormat.string(heavyHours)); "
            + "you called \(worthPhrase(heavyWorth, of: third)) worth it. "
            + "Your \(third) lightest averaged \(HoursFormat.string(lightHours)); "
            + "you called \(worthPhrase(lightWorth, of: third))."
    }

    /// "none of them", "2 of them", "all 3 of them" — a bare "0 of them"
    /// reads as a typing error in a sentence otherwise written in words.
    private static func worthPhrase(_ count: Int, of total: Int) -> String {
        if count == 0 { return "none of them" }
        if count == total { return total == 1 ? "it" : "all \(total) of them" }
        return "\(count) of them"
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Days are keyed in local time throughout the app; this has to agree
    /// with `WorkHistoryViewModel.dayKey` exactly or a week would gather
    /// the wrong days.
    private static func dayKeyFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter
    }
}
