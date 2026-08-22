import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The line above the inbox: what today is likely to ask of you, once the
/// messages and the meetings are read together.
///
/// Built in two passes on purpose. Each message is summarised on its own
/// first (`MailSummaryGenerator`), and only those one-line results — never
/// the message bodies — are read a second time to produce this. That keeps
/// the second prompt short enough to be accurate, means a cached summary is
/// reused rather than re-read, and holds to the rule that a body is looked
/// at once and never stored.
///
/// A day is more than its inbox, so the meetings go in too: "three reviews
/// back to back, and two people waiting on figures before the first one" is
/// the sentence worth having, and neither half of the app can write it
/// alone.
///
/// What you said you'd do goes in as well — today's intention and last
/// night's check-in, the two things in this app nobody else knows. That is
/// what lets the line say "two of today's messages are about the thing you
/// set out to finish" instead of counting the inbox at you, which the inbox
/// is already doing an inch away. The model is told to refer to the
/// intention, never to repeat it: the words are on screen directly below,
/// and `echoesGoal` throws away a brief that hands them back.
enum DayBriefGenerator {
    /// What the brief is written from: worked-out counts, and the lines the
    /// first pass produced.
    struct Input: Equatable {
        var actionLines: [String]
        var messageCount: Int
        var unreadCount: Int
        /// Messages whose deadline falls today or tomorrow.
        var dueSoonCount: Int
        var meetingTitles: [String]
        var meetingMinutes: Int
        /// What the reader wrote this morning they'd get done, verbatim.
        /// Empty on a day they didn't write one, which is most days for
        /// most people — everything here has to read well without it.
        var todaysGoals: String = ""
        /// What they wrote at yesterday's check-in.
        ///
        /// Read by the validator, never by the model — see
        /// `importsYesterday`. Yesterday's, not today's: at the hour this
        /// line is written today's check-in hasn't happened yet.
        var yesterdayReflection: String = ""

        var isEmpty: Bool { messageCount == 0 && meetingTitles.isEmpty }

        /// The intention, trimmed, or nil when there isn't one.
        var goal: String? {
            let text = todaysGoals.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        /// The day's items — meeting titles and message actions — that
        /// share real wording with the intention.
        ///
        /// Worked out here rather than left to the model, which is how this
        /// app handles every judgement of this kind (`MailDueDates` finds
        /// the candidate dates and the model only picks one;
        /// `WeeklyInsightGenerator` is handed a comparison rather than two
        /// numbers to subtract). Asked to spot the connection itself, the
        /// model reliably invented one: told a goal about a pricing model
        /// and a day of holiday rotas and leases, it wrote that the
        /// all-hands was about the pricing model. Told which items mention
        /// it — and told plainly when none do — it has a fact to phrase
        /// instead of a guess to make.
        ///
        /// Word overlap, not meaning: it can only miss a real connection,
        /// never assert a false one, and a missed connection costs a duller
        /// sentence where a false one costs the reader's trust in the whole
        /// line.
        var goalRelatedItems: [String] {
            guard let goal else { return [] }
            let goalWords = DayBriefGenerator.significantWords(goal)
            guard !goalWords.isEmpty else { return [] }
            return (meetingTitles + actionLines).filter {
                !DayBriefGenerator.significantWords($0).isDisjoint(with: goalWords)
            }
        }

        /// The deterministic line, always shown, with the generated one
        /// (when there is one) above it.
        ///
        /// It leads with what you said you'd do, word for word. No model is
        /// needed to quote a sentence back, and on the many Macs that can't
        /// run one that quote is the whole of what this app knows and the
        /// inbox doesn't. The counts follow it; they claim nothing they
        /// weren't handed.
        var fallbackSentence: String {
            var parts: [String] = []
            if let goal {
                parts.append(goal)
            }
            if messageCount > 0 {
                let noun = messageCount == 1 ? "message" : "messages"
                var mail = "\(messageCount) \(noun)"
                if unreadCount > 0 { mail += ", \(unreadCount) unread" }
                parts.append(mail)
            }
            if dueSoonCount > 0 {
                parts.append("\(dueSoonCount) due soon")
            }
            if !meetingTitles.isEmpty {
                let noun = meetingTitles.count == 1 ? "meeting" : "meetings"
                parts.append("\(meetingTitles.count) \(noun) · \(HoursFormat.string(Double(meetingMinutes) / 60))")
            }
            return parts.joined(separator: " · ")
        }
    }

    static var isAvailable: Bool { OnDeviceModel.isAvailable }

    /// Beyond this the brief stops being a glance and becomes something
    /// else to read, which defeats it.
    private static let wordLimit = 40

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    static func generate(for input: Input) async -> String? {
        guard OnDeviceModel.isAvailable else { return nil }
        guard !input.isEmpty else { return nil }
        // One message and one meeting don't need drawing together; the rows
        // themselves say it more precisely than a summary of two things can.
        guard input.messageCount + input.meetingTitles.count > 2 else { return nil }

        let session = LanguageModelSession(instructions: Instructions {
            """
            You write the opening line of someone's day in a personal \
            planning app, above their inbox and beside their calendar. You \
            are given the day's meetings and a list of already-written \
            actions, one per message, each saying what that message asks of \
            the reader. You may also be given what they wrote this morning \
            they would get done.

            Write at most two short sentences — thirty words in total — \
            saying what the day is likely to need from them. Draw the \
            threads together rather than listing: where several messages \
            want the same kind of work, or a message and a meeting are \
            plainly about the same thing, that connection is the sentence \
            worth writing. Where the day's messages or meetings bear on what \
            they said they would get done, say how — that is the most useful \
            sentence you can write. Where they don't bear on it at all, say \
            that instead, in the same breath as the rest. Address the reader \
            directly as "you".

            Do not restate what they said they would get done. It is \
            printed on the screen directly below your line, in their own \
            words, and a line that begins by agreeing with them tells them \
            nothing. Say what today does to it instead.

            Work only from what you are given. Do not attach an action to a \
            meeting unless you were told they go together — a message that \
            wants an answer and a meeting on the same subject are not the \
            same event, and saying they are puts something in their diary \
            that isn't there. Never name a person, never write an email \
            address, never invent a task that isn't in the list, and never \
            state a count — the numbers are shown beside \
            you and a second count that disagrees is worse than none.

            Plain sentences. No markdown, no emoji, no preamble, no heading.
            """
        })

        var lines: [String] = []
        // First, so the rest is read against it. Labelled as data to be
        // referred to rather than as an example of how to write — the same
        // care `MailSummaryGenerator` takes, after a prompt carrying sample
        // phrasing got the phrasing handed back word for word on unrelated
        // messages.
        if let goal = input.goal {
            lines.append("What they said this morning they would get done today: \(goal)")
            let related = input.goalRelatedItems
            if related.isEmpty {
                // Said outright, exactly as the no-meetings line is, and
                // after the same kind of failure: left to judge for itself
                // whether a day of holiday rotas bore on a pricing model,
                // the model decided it did.
                lines.append("Nothing in today's messages or meetings mentions it. Do not connect them to it; say the day is about something else.")
            } else {
                lines.append("Today's items that mention the same thing:")
                lines.append(contentsOf: related.map { "- \($0)" })
            }
        }
        // Yesterday's check-in is deliberately *not* in the prompt; see
        // `importsYesterday`.
        if input.meetingTitles.isEmpty {
            // Said outright, because leaving meetings out of the input
            // wasn't enough: the model read "book a time in your calendar"
            // among the actions and wrote a day with two meetings in it.
            // The validation catches that and throws the whole brief away,
            // so saying so here is what gets a brief at all on an empty day.
            lines.append("There are no meetings today. Do not mention meetings.")
        } else {
            lines.append("Meetings today:")
            lines.append(contentsOf: input.meetingTitles.map { "- \($0)" })
        }
        if !input.actionLines.isEmpty {
            lines.append("What the messages ask of them:")
            lines.append(contentsOf: input.actionLines.map { "- \($0)" })
        }
        guard !lines.isEmpty else { return nil }

        do {
            let response = try await session.respond(to: lines.joined(separator: "\n"))
            return valid(response.content, input: input)
        } catch {
            return nil
        }
    }
    #else
    /// Framework isn't in this SDK; the counts stand alone.
    static func generate(for input: Input) async -> String? { nil }
    #endif

    /// A brief worth showing, or nil to leave `fallbackSentence` in place.
    static func valid(_ raw: String, input: Input) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.split(separator: " ").count <= wordLimit else { return nil }
        guard !text.contains("@") else { return nil }
        guard !statesACount(text) else { return nil }
        guard !inventsMeetings(text, input: input) else { return nil }
        guard !echoesGoal(text, input: input) else { return nil }
        guard !importsYesterday(text, input: input) else { return nil }
        guard isGrounded(text, input: input) else { return nil }
        return text
    }

    /// Whether the brief is drawn from what it was given.
    ///
    /// The same guard the per-message lines carry, for the same reason and
    /// after the same failure: given four actions about bank statements and
    /// information requests, it produced "book a time in your calendar to
    /// finish the report", and there was no report. A summary of a day is
    /// worth having only if it is a summary of *that* day.
    private static func isGrounded(_ text: String, input: Input) -> Bool {
        let source = Set(
            (input.actionLines + input.meetingTitles + [input.goal].compactMap { $0 })
                .joined(separator: " ")
                .lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        )
        guard !source.isEmpty else { return false }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains { word in
            word.count >= 5 && !ignoredWords.contains(word) && source.contains(word)
        }
    }

    /// Words shared by every summary of every day, which prove nothing
    /// about whether this one describes the day in front of it.
    static let ignoredWords: Set<String> = [
        "about", "after", "again", "against", "already", "before", "being",
        "between", "could", "email", "emails", "message", "messages",
        "needs", "other", "should", "their", "there", "these", "thing",
        "things", "those", "today", "which", "while", "would", "your",
    ]

    /// Whether the brief is just the intention handed back.
    ///
    /// Being *about* the goal is the point of putting it in the prompt —
    /// what isn't wanted is the goal returned as though it were an
    /// observation, which reads as the app agreeing with you and sits
    /// directly above the same sentence in the reader's own words. So the
    /// test isn't whether the goal's words appear, it's whether anything
    /// else does: a brief that shares nearly all of the goal and adds
    /// almost nothing of its own is an echo.
    private static func echoesGoal(_ text: String, input: Input) -> Bool {
        guard let goal = input.goal else { return false }
        let goalWords = significantWords(goal)
        guard goalWords.count >= 2 else { return false }
        let briefWords = significantWords(text)
        let shared = Double(goalWords.intersection(briefWords).count) / Double(goalWords.count)
        guard shared >= 0.8 else { return false }
        return briefWords.subtracting(goalWords).count < 3
    }

    /// Whether the line has dragged yesterday's check-in into today.
    ///
    /// The check-in was in the prompt to begin with, as the issue asking
    /// for this suggested, and it had to come out. Handed "got stuck on the
    /// discount tiers", the model wrote *"you'll have to get stuck on the
    /// discount tiers again, because you didn't finish the pricing model
    /// yesterday"* — a sentence about the reader's past that nothing in
    /// this app knows to be true, and the sort of thing that makes the
    /// whole line untrustworthy. Handed "lost the afternoon to interviews",
    /// it put the interviews in today's diary.
    ///
    /// So the check-in is read the other way round: as words that must
    /// *not* turn up. Anything from last night that today's own messages
    /// and meetings don't also mention has been imported, and the brief
    /// goes in the bin. It stays part of the input because catching this is
    /// worth more than a sentence the model can't write honestly — the
    /// reader's own words are on the day panel where they wrote them.
    private static func importsYesterday(_ text: String, input: Input) -> Bool {
        let reflection = significantWords(input.yesterdayReflection)
        guard !reflection.isEmpty else { return false }
        // Words today is entitled to use: they're in front of the reader.
        let today = significantWords(
            (input.actionLines + input.meetingTitles + [input.todaysGoals]).joined(separator: " ")
        )
        let yesterdayOnly = reflection.subtracting(today)
        guard !yesterdayOnly.isEmpty else { return false }
        return !significantWords(text).isDisjoint(with: yesterdayOnly)
    }

    /// The words in a line that carry its meaning: long enough to mean
    /// something, and not one of the words every brief contains.
    static func significantWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .filter { $0.count >= 4 && !ignoredWords.contains($0) }
        )
    }

    /// Whether the line counts something.
    ///
    /// Digits *and* number words, unlike `MeetingSummaryGenerator`, which
    /// deliberately lets spelled-out numbers through because "one-to-ones"
    /// is a kind of meeting rather than a tally. Nothing of that sort
    /// belongs in a sentence about the shape of a day, and leaving the
    /// words out was how "two meetings scheduled" reached the screen on a
    /// day with no meetings at all.
    private static func statesACount(_ text: String) -> Bool {
        if text.contains(where: \.isNumber) { return true }
        let counts: Set<String> = [
            "one", "two", "three", "four", "five", "six", "seven", "eight",
            "nine", "ten", "dozen", "both",
        ]
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains { counts.contains($0) }
    }

    /// Whether the line talks about meetings on a day that has none.
    ///
    /// It happens, and it is the worst thing this line can do: a brief that
    /// invents two meetings sits directly beside a panel correctly saying
    /// the calendar is empty, and the reader has to work out which half of
    /// their own app to believe. The action lines are the likely source —
    /// several of them mention booking time — but the cause matters less
    /// than the rule, which is that the diary is not the model's to embellish.
    private static func inventsMeetings(_ text: String, input: Input) -> Bool {
        guard input.meetingTitles.isEmpty else { return false }
        let lowered = text.lowercased()
        return lowered.contains("meeting") || lowered.contains("appointment")
    }
}
