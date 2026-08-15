import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Parses a free-text description of someone's ideal work schedule — e.g.
/// "I'd like to work a balanced 9-5 week with 3h of meetings a day, and 5h
/// of focus time." — into structured `WorkPreferences`, using Apple's
/// on-device Foundation Models guided generation (`@Generable`/`@Guide`),
/// which constrains the model's output to the given shape rather than
/// asking it to produce free text we'd then have to parse ourselves.
///
/// Same macOS 26+ / Apple Intelligence availability gating as
/// `WeeklyInsightGenerator` — see its doc comment for why every reference
/// to FoundationModels types, not just the `import`, is behind
/// `#if canImport(FoundationModels)`.
enum WorkPreferencesGenerator {
    static var isAvailable: Bool { WeeklyInsightGenerator.isAvailable }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct Parsed {
        @Guide(description: "Total hours per week they want to work, e.g. 40. Default to 40 if not mentioned.")
        var weeklyTargetHours: Double
        @Guide(description: "24-hour hour (0-23) they want to start work, e.g. 9 for 9am. Default to 9 if not mentioned.")
        var workdayStartHour: Double
        @Guide(description: "24-hour hour (0-23) they want to end work, e.g. 17 for 5pm. Default to 17 if not mentioned.")
        var workdayEndHour: Double
        @Guide(description: "Desired hours of meetings per day, only if they actually mentioned meetings")
        var targetMeetingHoursPerDay: Double?
        @Guide(description: "Desired hours of focused/deep work per day, only if they actually mentioned focus time")
        var targetFocusHoursPerDay: Double?
    }

    /// Parses `text` into `WorkPreferences`, or nil if the model is
    /// unavailable, `text` is empty, or generation fails for any reason.
    @available(macOS 26.0, *)
    static func parse(_ text: String) async -> WorkPreferences? {
        guard SystemLanguageModel.default.availability == .available else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let session = LanguageModelSession(instructions: Instructions {
            """
            You convert a short, casual description of someone's ideal work \
            schedule into structured values. Use 24-hour hours (0 through 23) \
            for start/end times — e.g. "9-5" means start 9, end 17. Only fill \
            in meeting/focus hours per day if the person actually mentioned \
            them; leave them absent otherwise.
            """
        })

        do {
            let response = try await session.respond(to: text, generating: Parsed.self)
            let parsed = response.content
            return WorkPreferences(
                weeklyTargetHours: parsed.weeklyTargetHours,
                workdayStartHour: parsed.workdayStartHour,
                workdayEndHour: parsed.workdayEndHour,
                targetMeetingHoursPerDay: parsed.targetMeetingHoursPerDay,
                targetFocusHoursPerDay: parsed.targetFocusHoursPerDay
            )
        } catch {
            return nil
        }
    }
    #else
    /// Framework isn't in this SDK at all; always unavailable.
    static func parse(_ text: String) async -> WorkPreferences? {
        nil
    }
    #endif
}
