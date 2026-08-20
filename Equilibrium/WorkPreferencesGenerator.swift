import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Parses a free-text description of someone's ideal work schedule — e.g.
/// "I'd like to work 9 to 5 with an hour for lunch, 3h of meetings a day,
/// and 5h of focus time." — into structured `WorkPreferences`, using Apple's
/// on-device Foundation Models guided generation (`@Generable`/`@Guide`),
/// which constrains the model's output to the given shape rather than
/// asking it to produce free text we'd then have to parse ourselves.
///
/// Same macOS 26+ / Apple Intelligence availability gating as
/// `WeeklyInsightGenerator` — see `OnDeviceModel` for why every reference
/// to FoundationModels types, not just the `import`, is behind
/// `#if canImport(FoundationModels)`. This is a convenience, not the only
/// way in: when it's unavailable, `PreferencesView` shows
/// `WorkPreferencesForm`'s controls for the same settings.
enum WorkPreferencesGenerator {
    static var isAvailable: Bool { OnDeviceModel.isAvailable }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    @Generable
    struct Parsed {
        @Guide(description: "Total hours per week they want to work, not counting lunch or other breaks between shifts, e.g. 35. Default to 35 if not mentioned.")
        var weeklyTargetHours: Double
        @Guide(description: "24-hour hour (0-23) their morning shift starts, e.g. 9 for 9am. Default to 9 if not mentioned.")
        var morningStartHour: Double
        @Guide(description: "24-hour hour (0-24) their morning shift ends, i.e. when they break for lunch, e.g. 12 for noon. Default to 12 if not mentioned.")
        var morningEndHour: Double
        @Guide(description: "24-hour hour (0-23) their afternoon shift starts, i.e. when they come back from lunch, e.g. 13 for 1pm. Default to 13 if not mentioned.")
        var afternoonStartHour: Double
        @Guide(description: "24-hour hour (0-24) their afternoon shift ends, e.g. 17 for 5pm. Default to 17 if not mentioned.")
        var afternoonEndHour: Double
        @Guide(description: "24-hour hour (0-23) an optional evening shift starts, e.g. 18 for 6pm. Default to 18 if not mentioned.")
        var eveningStartHour: Double
        @Guide(description: "24-hour hour (0-24) an optional evening shift ends, e.g. 22 for 10pm. Default to 22 if not mentioned.")
        var eveningEndHour: Double
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
            schedule into structured values. Use 24-hour hours (0 through 24) \
            for start/end times. A day is made of up to three shifts — \
            morning, afternoon, evening — with the breaks between them, so \
            "9-5 with an hour for lunch" is a 9-12 morning and a 1-5 \
            afternoon. Weekly hours count only the shifts, never the breaks: \
            a 9-5 week with an hour's lunch is 35 hours, not 40. Only fill \
            in meeting/focus hours per day if the person actually mentioned \
            them; leave them absent otherwise.
            """
        })

        do {
            let response = try await session.respond(to: text, generating: Parsed.self)
            let parsed = response.content
            // The model is guided, not constrained — it can hand back a
            // shift that ends before it starts, or a 200-hour week — so
            // what it says is held to the same bounds the manual editor
            // enforces before it becomes settings. See `sanitized()`.
            return WorkPreferences(
                weeklyTargetHours: parsed.weeklyTargetHours,
                shifts: [
                    ShiftTemplate(slot: .morning, startHour: parsed.morningStartHour, endHour: parsed.morningEndHour),
                    ShiftTemplate(slot: .afternoon, startHour: parsed.afternoonStartHour, endHour: parsed.afternoonEndHour),
                    ShiftTemplate(slot: .evening, startHour: parsed.eveningStartHour, endHour: parsed.eveningEndHour),
                ],
                targetMeetingHoursPerDay: parsed.targetMeetingHoursPerDay,
                targetFocusHoursPerDay: parsed.targetFocusHoursPerDay
            ).sanitized()
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
