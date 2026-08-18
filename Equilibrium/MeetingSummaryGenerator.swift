import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One line describing a day's meetings, so a heavy diary doesn't push the
/// intention and check-in out of the panel.
///
/// Two halves, deliberately. The count and total come from arithmetic and
/// are always shown; the sentence about what kind of day it was comes from
/// the on-device model and is shown only where there is one. Most Macs
/// can't run it (see `OnDeviceModel`), so the summary that replaces a
/// hidden list can't itself depend on the model.
enum MeetingSummaryGenerator {
    /// "5 meetings · 4½h" — the part that always appears.
    static func countAndHours(_ meetings: [DayMeeting]) -> String? {
        guard !meetings.isEmpty else { return nil }
        let minutes = meetings.reduce(0) { $0 + $1.durationMinutes }
        let noun = meetings.count == 1 ? "meeting" : "meetings"
        return "\(meetings.count) \(noun) · \(HoursFormat.string(Double(minutes) / 60))"
    }

    static var isAvailable: Bool { OnDeviceModel.isAvailable }

    #if canImport(FoundationModels)
    /// A short phrase for the shape of the day — "mostly interviews, one
    /// long research block". Nil when the model is unavailable or the day
    /// is quiet enough that the list speaks for itself.
    @available(macOS 26.0, *)
    static func generateGist(for meetings: [DayMeeting]) async -> String? {
        guard OnDeviceModel.isAvailable else { return nil }
        guard meetings.count > 1 else { return nil }

        let session = LanguageModelSession(instructions: Instructions {
            """
            You label one day's calendar in a personal work-tracking app. \
            Given the meeting titles and their lengths, reply with a short \
            fragment — at most eight words — naming the kinds of thing on \
            that day, so someone recognises it at a glance.

            Work only from the words in the titles. Never merge two titles \
            into one activity, never name a person, never say who did \
            anything, and never add a detail that isn't written there. Group \
            similar titles ("three interviews") rather than listing them all. \
            Don't state the count or the total hours: those are already \
            shown.

            Reply with the fragment alone — not a sentence, no subject, no \
            verb tense, no markdown, no emoji, no closing full stop.
            """
        })

        let lines = meetings.map { meeting in
            "\(meeting.title) (\(meeting.durationMinutes) min)"
        }

        do {
            let response = try await session.respond(to: lines.joined(separator: "\n"))
            // Trailing punctuation is asked against and still turns up, so
            // it's removed here rather than left to the model.
            let text = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".;,"))
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
    #else
    /// Framework isn't in this SDK at all; the count and hours stand alone.
    static func generateGist(for meetings: [DayMeeting]) async -> String? {
        nil
    }
    #endif
}
