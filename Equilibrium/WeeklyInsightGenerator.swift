import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Generates a short, friendly natural-language observation about a work
/// week using Apple's on-device Foundation Models framework (macOS 26+).
/// Inference runs entirely on-device: no network requests, no API keys,
/// nothing leaves the Mac. On older macOS, or if Apple Intelligence isn't
/// enabled/downloaded, this is simply unavailable and callers should treat
/// a nil result as "don't show anything."
///
/// The FoundationModels framework itself doesn't exist in SDKs older than
/// macOS 26 (e.g. the Xcode 16.4 / macOS 15 SDK used by CI), so every
/// reference to its types — not just the `import` — has to be compiled out
/// with `#if canImport(FoundationModels)`. A `#available` guard alone isn't
/// enough: that's a runtime check and doesn't help the compiler resolve
/// symbols that don't exist in the SDK at all.
enum WeeklyInsightGenerator {
    /// A completed (or in-progress) week's average daily breakdown, used
    /// both as the LLM prompt's input and as the data behind the
    /// deterministic fallback sentence shown when the model is unavailable.
    ///
    /// No "focus time" here — it was always a derived guess (effective
    /// hours minus meetings), never a directly measured quantity, so it's
    /// been dropped entirely. Only meetings (real calendar times) and work/
    /// break (from wake/sleep logs) are things we actually know.
    struct WeekHeaderStats: Equatable {
        let workAvgHours: Double
        let breakAvgHours: Double
        let meetingAvgHours: Double?
        /// The configured weekly target expressed as an hours/weekday rate
        /// (weeklyTargetHours / 5), so it's directly comparable to
        /// `workAvgHours` regardless of how many days this week have data
        /// so far — a strict weekly-total comparison would read as "under"
        /// for any week that isn't finished yet.
        let targetHoursPerDay: Double

        /// Averages effective/break/meeting hours per weekday across
        /// whichever days in `spans` have any recorded data. Meeting only
        /// averages over days with calendar data; nil when no day in the
        /// week has any. Returns nil when no day has any data at all.
        static func compute(from spans: [WorkdaySpan?], weeklyTargetHours: Double) -> WeekHeaderStats? {
            let daysWithData = spans.compactMap { $0 }.filter { $0.hours > 0 }
            guard !daysWithData.isEmpty else { return nil }

            let workAvg = daysWithData.reduce(0.0) { $0 + $1.effectiveHours } / Double(daysWithData.count)
            let breakAvg = daysWithData.reduce(0.0) { $0 + Double($1.breakMinutesUsed) / 60.0 } / Double(daysWithData.count)

            let daysWithMeetingData = daysWithData.filter { $0.hasCalendarData }
            let meetingAvg = daysWithMeetingData.isEmpty ? nil :
                daysWithMeetingData.reduce(0.0) { $0 + Double($1.meetingMinutes) / 60.0 } / Double(daysWithMeetingData.count)

            return WeekHeaderStats(
                workAvgHours: workAvg,
                breakAvgHours: breakAvg,
                meetingAvgHours: meetingAvg,
                targetHoursPerDay: weeklyTargetHours / 5
            )
        }

        /// How far the average weekday sat from target, already worked out
        /// and worded, so the model never has to subtract anything: asked to
        /// do the arithmetic itself it has said "3 hours over" about a week
        /// averaging 4h against an 8h target. It phrases the sentence; the
        /// comparison at the heart of it is decided here.
        var targetComparison: String {
            let difference = workAvgHours - targetHoursPerDay
            if abs(difference) < 0.25 {
                return "right on target"
            }
            return difference > 0
                ? "\(HoursFormat.string(difference)) over target"
                : "\(HoursFormat.string(-difference)) under target"
        }

        /// The deterministic "Nh meetings/day, ..." sentence, used whenever
        /// the LLM is unavailable or hasn't produced a summary yet.
        var fallbackSentence: String {
            if let meetingAvgHours {
                return "\(HoursFormat.string(meetingAvgHours)) meetings/day, \(HoursFormat.string(breakAvgHours)) breaks a day, and \(HoursFormat.string(workAvgHours)) work/day"
            }
            return "\(HoursFormat.string(breakAvgHours)) breaks a day, and \(HoursFormat.string(workAvgHours)) work/day"
        }
    }

    /// Whether an on-device model is ready to use right now.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.availability == .available
        #else
        return false
        #endif
    }

    #if canImport(FoundationModels)
    /// Produces one short "You worked ..." sentence summarizing a week's
    /// average daily breakdown, for display above that week's bars in the
    /// chart header. Nil if the model is unavailable or generation fails.
    @available(macOS 26.0, *)
    static func generateWeekHeaderSummary(for stats: WeekHeaderStats) async -> String? {
        guard SystemLanguageModel.default.availability == .available else { return nil }

        let session = LanguageModelSession(instructions: Instructions {
            """
            You are a calm, plain-spoken assistant inside a personal work-hours \
            tracking app, writing a one-line caption that sits directly above a \
            small chart of one work week, which may be the current week or an \
            earlier one — so never call it "this week". Given that week's \
            average-per-weekday \
            work hours and their target, write a single concise sentence (max \
            ~16 words) starting with "You worked" whose main point is the \
            "Versus target" line given below — state it plainly, not just a \
            neutral recap. Use that line's direction and amount exactly as \
            given: never work out the difference yourself, and never contradict \
            it. Mention meetings only if given below, and only in passing — the \
            comparison against target is what matters. Never invent numbers \
            that weren't given to you. When a duration is a half hour, \
            write it with the ½ symbol (e.g. "3½h"), never "3.5h" or "three and \
            a half hours". Use ordinary sentence case throughout: never put a \
            word in capitals for emphasis. No markdown, no emoji, no \
            exclamation marks, no preamble like "Here's" — just the sentence \
            itself.
            """
        })

        // Rounded to the nearest half hour before it ever reaches the model,
        // so it can't echo back noisy precision like "8.0" or "7.83".
        // No "this week" anywhere in the input: the chart can be showing any
        // week you've paged back to, and the model repeats the phrase back
        // when it's there, captioning last week as though it were this one.
        var lines = [
            "Average per weekday in the week shown:",
            "Work: \(HoursFormat.string(stats.workAvgHours))",
            "Target: \(HoursFormat.string(stats.targetHoursPerDay))",
            "Versus target: \(stats.targetComparison)",
        ]
        if let meeting = stats.meetingAvgHours {
            lines.append("Meetings: \(HoursFormat.string(meeting))")
        }
        lines.append("Breaks: \(HoursFormat.string(stats.breakAvgHours))")

        do {
            let response = try await session.respond(to: lines.joined(separator: "\n"))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
    #else
    /// Framework isn't in this SDK at all; always unavailable.
    static func generateWeekHeaderSummary(for stats: WeekHeaderStats) async -> String? {
        nil
    }
    #endif
}
