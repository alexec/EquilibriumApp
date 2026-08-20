import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns one message into one line about what *you* might do with it.
///
/// The orientation is the whole point. "This email is about the Q3 budget"
/// describes the artefact and tells you nothing you didn't get from the
/// subject line, which is already on screen directly above it. What earns
/// the row is the next action: what this message wants from you, and by
/// when. Everything in the prompt below pushes that way, and the
/// validation throws away answers that drift back into description.
///
/// Same availability shape as `MeetingSummaryGenerator`: guarded by both
/// `#if canImport(FoundationModels)` and `@available(macOS 26.0, *)`,
/// because the framework is missing from pre-macOS-26 SDKs entirely and a
/// runtime check alone won't compile on CI.
enum MailSummaryGenerator {
    static var isAvailable: Bool { OnDeviceModel.isAvailable }

    /// Bump whenever the prompt or the validation below changes, so lines
    /// written by the previous version are regenerated rather than served
    /// from `MailSummaryStore` forever.
    ///
    /// 2: dropped the example actions from the instructions, which the
    /// model was returning verbatim, and added the grounding check.
    /// 3: dropped the list of verbs that replaced them, which the model
    /// then returned verbatim in turn — "reply", alone, on five messages
    /// running. Nothing quotable is left in the instructions, and a line
    /// too short to name anything is now rejected.
    /// 4: the sender's first person was being carried straight through —
    /// "book a time on my calendar" on a message asking for a slot in
    /// theirs, which reads as though the app owned the diary. Asking for
    /// the reader's voice wasn't enough on its own, so it's checked too.
    /// 6: added the gist — a sentence or two on what the message says, for
    /// the popover that replaced the row's inline buttons.
    static let promptVersion = 6

    /// At most this many words in an action line. Long enough for "send the
    /// draft agenda before the workshop", short enough that a column of
    /// forty of them stays scannable.
    private static let wordLimit = 14
    /// Below this a line carries no more information than the subject it
    /// sits under. See `validAction`.
    private static let minimumWords = 3

    /// The summary every Mac can produce: no action line, and the soonest
    /// believable date the detector found.
    ///
    /// Not a degraded mode so much as the common one — most Macs can't run
    /// the model (see `OnDeviceModel`) — so the row is designed to read
    /// properly with `action` empty, falling back to the sender and subject
    /// it already has.
    static func fallback(for message: MailMessage, candidates: [MailDueDates.Candidate]) -> MailSummary {
        MailSummary(
            messageID: message.id,
            action: "",
            gist: "",
            dueDate: MailDueDates.soonest(candidates),
            needsReply: false,
            savedAt: Date(),
            generatorVersion: promptVersion
        )
    }

    #if canImport(FoundationModels)
    /// What the model is asked to fill in. Guided generation rather than
    /// free text, as in `WorkPreferencesGenerator`, so the due date comes
    /// back as a choice from a list instead of a sentence to parse.
    @available(macOS 26.0, *)
    /// Internal rather than private: the `@Generable` macro generates code
    /// that refers to this type from outside its own scope.
    @Generable
    struct Draft {
        @Guide(description: "What the reader should do about this message, as an instruction to them, at most 14 words. Start with a verb. Never describe what the message says.")
        var action: String
        @Guide(description: "What the message says, in one or two short sentences, for a reader deciding whether to open it. Say what it is about and what the sender wants. Do not repeat the subject line back.")
        var gist: String
        @Guide(description: "The number printed beside the date this message is due by, chosen from the numbered list. Use -1 when the message has no deadline for the reader, or the list is empty.")
        var dueChoice: Int
        @Guide(description: "True when the sender is waiting on a written answer from the reader.")
        var needsReply: Bool
    }

    @available(macOS 26.0, *)
    static func generate(for message: MailMessage, candidates: [MailDueDates.Candidate]) async -> MailSummary {
        guard OnDeviceModel.isAvailable else { return fallback(for: message, candidates: candidates) }

        let session = LanguageModelSession(instructions: Instructions {
            """
            You read one email inside a personal planning app and say what \
            the reader might do about it. The reader is the person the \
            message was sent to. Write to them, about their next move — \
            never a description of what the message contains. They can see \
            the subject line and the sender already; those sit on screen \
            directly above what you write.

            Write one instruction to them, between four and fourteen words, \
            beginning with a verb. The verb alone is never an answer: what \
            makes the line worth reading is the thing it names — which \
            document, which account, which decision, which question — taken \
            from the words of the message in front of you.

            An instruction that would fit any email is wrong. Before you \
            answer, find the one specific thing this message is about, and \
            put it in the line. If the message asks nothing of anyone — a \
            newsletter, a receipt, an automated notice — name what it is \
            instead, still in four words or more.

            Write in the reader's voice, about their work: "book a time in \
            your calendar", never "book a time in my calendar". The message \
            was written by someone else, and its "my" and "our" are theirs, \
            not yours and not the reader's.

            Never name anyone. The sender's name is shown beside your line, \
            and a name you write there is either a repetition of it or a \
            mistake. Say "the sender", or better, leave the person out and \
            name the thing to be done.

            Never write a day, a date or a time. The deadline is shown \
            separately as its own label, and a second one in your words \
            contradicts it whenever you and the detector disagree. Choose \
            the deadline by number from the list instead.

            Reply with the fields asked for, nothing else: no markdown, no \
            emoji, no quotation marks, no closing full stop.
            """
        })

        var lines = [
            "Subject: \(message.displaySubject)",
            "From: \(message.sender.displayName)",
            "Other people on it: \(message.recipients.count)",
        ]
        if candidates.isEmpty {
            lines.append("Dates found in the message: none. Use -1.")
        } else {
            lines.append("Dates found in the message, to choose a deadline from by number:")
            // Numbered for the model, indexed from zero on the way back —
            // the mapping is checked below rather than trusted.
            for (index, candidate) in candidates.enumerated() {
                lines.append("\(index): \(candidate.phrase)")
            }
        }
        lines.append("Message:")
        lines.append(message.bodyExcerpt)

        do {
            let response = try await session.respond(
                to: lines.joined(separator: "\n"),
                generating: Draft.self
            )
            let draft = response.content
            return MailSummary(
                messageID: message.id,
                action: validAction(draft.action, message: message) ?? "",
                gist: validGist(draft.gist, message: message) ?? "",
                dueDate: dueDate(choice: draft.dueChoice, candidates: candidates),
                needsReply: draft.needsReply,
                savedAt: Date(),
                generatorVersion: promptVersion
            )
        } catch {
            return fallback(for: message, candidates: candidates)
        }
    }

    /// The chosen date, or the detector's own answer when the choice is out
    /// of range. An index that isn't in the list is the model inventing a
    /// deadline, which is precisely what handing it a list was meant to
    /// prevent — so the list wins.
    private static func dueDate(choice: Int, candidates: [MailDueDates.Candidate]) -> Date? {
        guard candidates.indices.contains(choice) else {
            return choice == -1 ? nil : MailDueDates.soonest(candidates)
        }
        return candidates[choice].date
    }
    #else
    /// Framework isn't in this SDK at all; every Mac gets the fallback.
    static func generate(for message: MailMessage, candidates: [MailDueDates.Candidate]) async -> MailSummary {
        fallback(for: message, candidates: candidates)
    }
    #endif

    /// At most this many words in a gist. Two sentences, not a précis: the
    /// popover is for deciding whether to open the message, and past this
    /// it's quicker to open it.
    private static let gistWordLimit = 45

    /// A gist worth showing, or nil to leave the popover to the subject.
    ///
    /// Held to the same grounding rule as the action line, and for the same
    /// reason: an invented summary of an email is worse than no summary,
    /// because there's nothing on screen to contradict it.
    static func validGist(_ raw: String, message: MailMessage) -> String? {
        let text = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !text.isEmpty else { return nil }
        guard text.split(separator: " ").count <= gistWordLimit else { return nil }
        guard !text.contains("@") else { return nil }
        guard isGrounded(text, message: message) else { return nil }
        return text
    }

    /// An action line worth showing, or nil to fall back to the sender and
    /// subject.
    ///
    /// Everything here is asked for in the prompt and turns up anyway,
    /// which is the same reason `MeetingSummaryGenerator` re-checks its own
    /// instructions after the fact.
    ///
    /// What this can't catch is a name the model invented outright — there
    /// is no way from here to tell a hallucinated colleague from a project
    /// codename. That's why the prompt forbids naming anyone at all and the
    /// row prints the real sender next to the line: a name that doesn't
    /// match the one beside it is visible to the reader even when it isn't
    /// visible here.
    static func validAction(_ raw: String, message: MailMessage) -> String? {
        let text = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
        guard !text.isEmpty else { return nil }
        let words = text.split(separator: " ")
        guard words.count <= wordLimit else { return nil }
        // A bare verb is not an instruction. Asked for a line beginning
        // with one, the model has answered "reply" and nothing else, on
        // message after message — true of all of them and useful about
        // none. Below the floor the row shows the subject alone, which
        // says strictly more.
        guard words.count >= minimumWords else { return nil }
        // An address is never the next action, and it's the one piece of
        // the message that shouldn't be repeated back in a summary.
        guard !text.contains("@") else { return nil }
        guard !speaksAsSomeoneElse(text) else { return nil }
        guard !statesADate(text) else { return nil }
        guard !namesAParticipant(text, message: message) else { return nil }
        guard isGrounded(text, message: message) else { return nil }
        return text
    }

    /// Whether the line has taken the sender's first person on.
    ///
    /// "Book a time on my calendar" is what the message said, and it is
    /// wrong twice over here: the calendar isn't the app's, and the line is
    /// addressed to the reader about their own work. The prompt asks for
    /// the reader's voice and the model carries the sender's through
    /// anyway, so the answer is checked. Nothing legitimate needs a first
    /// person: an instruction to you is about yours.
    private static func speaksAsSomeoneElse(_ text: String) -> Bool {
        let firstPerson: Set<String> = ["my", "mine", "me", "our", "ours", "us", "i"]
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains { firstPerson.contains($0) }
    }

    /// Whether the line is about *this* message.
    ///
    /// This one is not defensive tidying — it catches a failure seen in the
    /// running app. Given an instruction containing example actions, the
    /// model returned one of the examples word for word, and returned the
    /// same one for three unrelated messages in a row: two information
    /// requests and a bank notice all came back as "book a room for the
    /// workshop", which was a phrase from the prompt and from nowhere else.
    /// The examples are gone now, but an invented action is far worse than
    /// a missing one — it puts a task on your list that nobody asked of you
    /// — so the answer is also checked against the message it describes.
    ///
    /// A line has to share at least one real word with the subject or the
    /// body, ignoring the words common to all mail. Nothing is exempt: an
    /// answer that borrows no word from the message is either invented or
    /// too generic to be worth the row, and both fall back to the subject.
    private static func isGrounded(_ text: String, message: MailMessage) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let source = Set(
            (message.subject + " " + message.bodyExcerpt)
                .lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        )
        return words.contains { word in
            word.count >= 4 && !Self.commonWords.contains(word) && source.contains(word)
        }
    }

    /// Words that say nothing about which message a line belongs to, so
    /// finding one in both proves nothing. Verbs the prompt asks for are
    /// here too: "reply" appears in most emails and in most answers.
    private static let commonWords: Set<String> = [
        "reply", "send", "read", "book", "review", "approve", "decide",
        "chase", "file", "this", "that", "with", "from", "your", "their",
        "them", "they", "have", "back", "about", "before", "after", "when",
        "what", "which", "there", "here", "will", "would", "should", "need",
        "needs", "make", "take", "time", "email", "message", "please",
        "thanks", "sent", "into", "over", "then", "than", "some", "more",
    ]

    /// Whether the line puts a date in words. The due label owns the date;
    /// two of them disagreeing is worse than one of them missing.
    private static func statesADate(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let dateWords = [
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "may", "june", "july",
            "august", "september", "october", "november", "december",
            "today", "tomorrow", "tonight", "yesterday", "am", "pm",
        ]
        let words = lowered.split(whereSeparator: { !$0.isLetter })
        return words.contains { dateWords.contains(String($0)) }
    }

    /// Whether the line names someone already named beside it.
    ///
    /// Conservative on purpose, and it does over-reach: a participant called
    /// Mark costs us "mark the invoice as paid", which is rejected and falls
    /// back to the subject line. That's the cheap direction to be wrong in —
    /// a row that says slightly less, rather than one that repeats the name
    /// printed two inches to its left.
    private static func namesAParticipant(_ text: String, message: MailMessage) -> Bool {
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        for person in message.participants {
            let nameWords = person.displayName.lowercased().split(separator: " ").map(String.init)
            if nameWords.contains(where: { words.contains($0) && $0.count > 2 }) {
                return true
            }
        }
        return false
    }
}
