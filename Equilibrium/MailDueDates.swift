import Foundation

/// When a message wants dealing with, worked out from the text rather than
/// asked of the model.
///
/// This exists so the on-device model never has to answer "what date is
/// next Thursday" — the same reason `WeeklyInsightGenerator` hands it a
/// worked-out `targetComparison` instead of two numbers to subtract. The
/// detector finds the candidates and resolves them to real dates; the
/// model's only job is to say which one the message is actually due by,
/// and it can only choose from this list or decline. A model left to write
/// a date writes a plausible one.
///
/// It is also the whole of the due-date feature on the Macs that can't run
/// the model at all — `soonest(_:)` picks a sensible answer unaided.
enum MailDueDates {
    /// A date found in the text, and the words it was found in — the words
    /// are what a prompt can show the model, since "Thursday" means more to
    /// it than an ISO timestamp.
    struct Candidate: Equatable {
        let date: Date
        let phrase: String
    }

    /// How far ahead a detected date is still believable as a deadline.
    /// Past this it's a contract renewal, a copyright line, or a date in
    /// quoted history — not something to do this week.
    private static let horizonDays = 90

    /// How far back a detected date can sit and still be worth showing.
    /// A little slack, so a deadline that passed this morning still counts
    /// as a deadline rather than vanishing at midnight.
    private static let graceHours = 12

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// Every believable due date in a message, soonest first.
    ///
    /// Subject first and body second, deliberately: a date in the subject
    /// line is the one someone meant you to see, and it should be the one
    /// offered first when the model is picking between them.
    static func candidates(in message: MailMessage, now: Date = Date()) -> [Candidate] {
        let found = detect(message.subject, now: now) + detect(message.bodyExcerpt, now: now)

        // Two mentions of one deadline — the subject and the sign-off — are
        // one candidate. Matched to the minute, since "Thursday" and
        // "Thursday 5pm" are genuinely different answers.
        var seen = Set<Int>()
        return found.filter { candidate in
            seen.insert(Int(candidate.date.timeIntervalSince1970 / 60)).inserted
        }
    }

    private static func detect(_ text: String, now: Date) -> [Candidate] {
        guard let detector, !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let earliest = now.addingTimeInterval(-Double(graceHours) * 3600)
        let latest = now.addingTimeInterval(Double(horizonDays) * 86_400)

        return detector.matches(in: text, range: range).compactMap { match in
            guard let date = match.date, date >= earliest, date <= latest else { return nil }
            guard let phraseRange = Range(match.range, in: text) else { return nil }
            return Candidate(date: date, phrase: String(text[phraseRange]))
        }
        .sorted { $0.date < $1.date }
    }

    /// The answer without a model: the soonest believable date, which is
    /// nearly always the one that matters. A message carrying two dates is
    /// usually "the workshop is on the 20th, slides by the 18th", and the
    /// 18th is the one you need.
    static func soonest(_ candidates: [Candidate]) -> Date? {
        candidates.min { $0.date < $1.date }?.date
    }
}
