import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Generates a short, friendly natural-language observation about the
/// current work week using Apple's on-device Foundation Models framework
/// (macOS 26+). Inference runs entirely on-device: no network requests, no
/// API keys, nothing leaves the Mac. On older macOS, or if Apple
/// Intelligence isn't enabled/downloaded, this is simply unavailable and
/// callers should treat a nil result as "don't show anything."
///
/// The FoundationModels framework itself doesn't exist in SDKs older than
/// macOS 26 (e.g. the Xcode 16.4 / macOS 15 SDK used by CI), so every
/// reference to its types — not just the `import` — has to be compiled out
/// with `#if canImport(FoundationModels)`. A `#available` guard alone isn't
/// enough: that's a runtime check and doesn't help the compiler resolve
/// symbols that don't exist in the SDK at all.
enum WeeklyInsightGenerator {
    struct WeekSummary {
        var todayWeekday: String
        var daysWorked: [(weekday: String, hours: Double)]
        var workedSoFarHours: Double
        var targetHours: Double
        var todaysRecommendedHours: Double?
    }

    /// A completed (or in-progress) week's average daily breakdown, used
    /// both as the LLM prompt's input and as the data behind the
    /// deterministic fallback sentence shown when the model is unavailable.
    struct WeekHeaderStats: Equatable {
        let workAvgHours: Double
        let breakAvgHours: Double
        let meetingAvgHours: Double?
        let focusAvgHours: Double?

        /// Averages effective/break/meeting/focus hours per weekday across
        /// whichever days in `spans` have any recorded data. Meeting/focus
        /// only average over days with calendar data (or a manual split
        /// override); nil when no day in the week has either. Returns nil
        /// when no day has any data at all.
        static func compute(from spans: [WorkdaySpan?]) -> WeekHeaderStats? {
            let daysWithData = spans.compactMap { $0 }.filter { $0.hours > 0 }
            guard !daysWithData.isEmpty else { return nil }

            let workAvg = daysWithData.reduce(0.0) { $0 + $1.effectiveHours } / Double(daysWithData.count)
            let breakAvg = daysWithData.reduce(0.0) { $0 + Double($1.breakMinutesUsed) / 60.0 } / Double(daysWithData.count)

            let daysWithMeetingData = daysWithData.filter { $0.displayMeetingMinutes != nil }
            let meetingAvg = daysWithMeetingData.isEmpty ? nil :
                daysWithMeetingData.reduce(0.0) { $0 + Double($1.displayMeetingMinutes ?? 0) / 60.0 } / Double(daysWithMeetingData.count)
            let focusAvg = daysWithMeetingData.isEmpty ? nil :
                daysWithMeetingData.reduce(0.0) { $0 + Double($1.focusMinutes ?? 0) / 60.0 } / Double(daysWithMeetingData.count)

            return WeekHeaderStats(workAvgHours: workAvg, breakAvgHours: breakAvg, meetingAvgHours: meetingAvg, focusAvgHours: focusAvg)
        }

        /// The deterministic "Nh meetings/day, ..." sentence, used whenever
        /// the LLM is unavailable or hasn't produced a summary yet.
        var fallbackSentence: String {
            func h(_ value: Double) -> String { "\(Int(value.rounded()))h" }
            if let meetingAvgHours, let focusAvgHours {
                return "\(h(meetingAvgHours)) meetings/day, \(h(focusAvgHours)) focus time/day, \(h(breakAvgHours)) breaks a day, and \(h(workAvgHours)) work/day"
            }
            return "\(h(breakAvgHours)) breaks a day, and \(h(workAvgHours)) work/day"
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
    /// Produces one short sentence about the week's pattern, or nil if the
    /// model is unavailable or generation fails for any reason (this is a
    /// nice-to-have, so failures are silent rather than surfaced).
    @available(macOS 26.0, *)
    static func generateInsight(for summary: WeekSummary) async -> String? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        guard !summary.daysWorked.isEmpty else { return nil }

        let session = LanguageModelSession(instructions: Instructions {
            """
            You are a calm, encouraging assistant inside a personal work-hours \
            tracking app. Given a short summary of someone's work week so far, \
            write ONE plain-English sentence (max ~20 words) noting something \
            worth mentioning: their pace toward the weekly target, an unusually \
            long or short day, or a steady rhythm. Be warm but not sycophantic, \
            and never invent numbers that weren't given to you. No markdown, no \
            emoji, no exclamation marks, no preamble like "Here's" — just \
            the sentence itself.
            """
        })

        let daysDescription = summary.daysWorked
            .map { "\($0.weekday) \(String(format: "%.1f", $0.hours))h" }
            .joined(separator: ", ")

        let recommendationLine: String
        if let recommended = summary.todaysRecommendedHours {
            recommendationLine = "Recommended for \(summary.todayWeekday) (today): \(String(format: "%.1f", recommended))h."
        } else {
            recommendationLine = ""
        }

        let prompt = """
        Days worked this week so far: \(daysDescription)
        Total worked so far: \(String(format: "%.1f", summary.workedSoFarHours))h
        Weekly target: \(String(format: "%.0f", summary.targetHours))h
        \(recommendationLine)
        """

        do {
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

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
            small chart of one work week. Given that week's average-per-weekday \
            breakdown, write ONE short sentence (max ~16 words) starting with \
            "You worked" that summarizes the week's shape — mention the meeting/ \
            focus balance only if both are given below. Never invent numbers that \
            weren't given to you. No markdown, no emoji, no exclamation marks, no \
            preamble like "Here's" — just the sentence itself.
            """
        })

        func h(_ value: Double) -> String { String(format: "%.1f", value) }
        var lines = ["Average per weekday this week:", "Work: \(h(stats.workAvgHours))h"]
        if let meeting = stats.meetingAvgHours, let focus = stats.focusAvgHours {
            lines.append("Meetings: \(h(meeting))h")
            lines.append("Focus: \(h(focus))h")
        }
        lines.append("Breaks: \(h(stats.breakAvgHours))h")

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
    static func generateInsight(for summary: WeekSummary) async -> String? {
        nil
    }

    static func generateWeekHeaderSummary(for stats: WeekHeaderStats) async -> String? {
        nil
    }
    #endif
}
