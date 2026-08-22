import Foundation

/// One week's answer to the only question this app is really asking: was
/// that worth it?
///
/// Keyed by the week's Saturday in the same `yyyy-MM-dd` form days are
/// keyed by, because the app's week is Saturday→Friday (`WeekCalendar`) and
/// its first day is the only unambiguous name a week has. An ISO week
/// number would name a different seven days than the chart draws.
///
/// One question, and a verdict that takes one click. Not a retro form: the
/// day panel already asks for three things, and a Friday that opens six
/// more boxes is a Friday you learn to close. This has to stay cheap enough
/// to answer honestly forty times a year.
struct WeeklyReview: Codable, Equatable, Identifiable {
    var id: String { weekKey }
    /// The `dayKey` of the week's Saturday.
    let weekKey: String

    /// Was it worth it — in as many or as few words as the week deserves.
    var answer: String = ""
    /// The coarse version of the same question, so weeks can be put in an
    /// order later without anything having to read the prose.
    var verdict: Verdict?
    /// When the week was first answered. Kept for the same reason
    /// `DailyIntention` keeps its timestamps: editing an old week's wording
    /// shouldn't restamp it as though it were written now.
    var answeredAt: Date?

    /// Three steps, deliberately. Five would invite the middle two to blur,
    /// and the question is one people answer with their gut.
    enum Verdict: String, Codable, CaseIterable, Identifiable, Comparable {
        case notWorthIt
        case mixed
        case worthIt

        var id: String { rawValue }

        /// Written as an answer to "was that worth it?", not as a label.
        var label: String {
            switch self {
            case .notWorthIt: return "No"
            case .mixed: return "Mixed"
            case .worthIt: return "Yes"
            }
        }

        /// What it means on its own, for the tooltip and for VoiceOver,
        /// where "No" by itself says nothing.
        var meaning: String {
            switch self {
            case .notWorthIt: return "The hours weren't worth it"
            case .mixed: return "Some of the hours were worth it"
            case .worthIt: return "The hours were worth it"
            }
        }

        private var rank: Int {
            switch self {
            case .notWorthIt: return 0
            case .mixed: return 1
            case .worthIt: return 2
            }
        }

        static func < (lhs: Verdict, rhs: Verdict) -> Bool { lhs.rank < rhs.rank }
    }

    var hasAnswer: Bool {
        verdict != nil || !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(weekKey: String, answer: String = "", verdict: Verdict? = nil, answeredAt: Date? = nil) {
        self.weekKey = weekKey
        self.answer = answer
        self.verdict = verdict
        self.answeredAt = answeredAt
    }

    private enum CodingKeys: String, CodingKey {
        case weekKey, answer, verdict, answeredAt
    }

    /// Hand-written for the same reason `WorkdaySpan`'s is: everything
    /// after `weekKey` decodes with a default, so a file written by today's
    /// version still loads once this gains a field.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weekKey = try container.decode(String.self, forKey: .weekKey)
        answer = try container.decodeIfPresent(String.self, forKey: .answer) ?? ""
        verdict = try container.decodeIfPresent(Verdict.self, forKey: .verdict)
        answeredAt = try container.decodeIfPresent(Date.self, forKey: .answeredAt)
    }
}
