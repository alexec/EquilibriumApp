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

        var isEmpty: Bool { messageCount == 0 && meetingTitles.isEmpty }

        /// The deterministic line, shown whenever there's no model or the
        /// generated one didn't survive validation. Counts only — it claims
        /// nothing it hasn't been handed.
        var fallbackSentence: String {
            var parts: [String] = []
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
            the reader.

            Write at most two short sentences — thirty words in total — \
            saying what the day is likely to need from them. Draw the \
            threads together rather than listing: where several messages \
            want the same kind of work, or a message and a meeting are \
            plainly about the same thing, that connection is the sentence \
            worth writing. Address the reader directly as "you".

            Work only from what you are given. Never name a person, never \
            write an email address, never invent a task that isn't in the \
            list, and never state a count — the numbers are shown beside \
            you and a second count that disagrees is worse than none.

            Plain sentences. No markdown, no emoji, no preamble, no heading.
            """
        })

        var lines: [String] = []
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
            (input.actionLines + input.meetingTitles)
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
    private static let ignoredWords: Set<String> = [
        "about", "after", "again", "against", "already", "before", "being",
        "between", "could", "email", "emails", "message", "messages",
        "needs", "other", "should", "their", "there", "these", "thing",
        "things", "those", "today", "which", "while", "would", "your",
    ]

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
