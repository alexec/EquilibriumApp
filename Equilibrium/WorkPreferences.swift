import Foundation

/// One of the three slots a day's work can sit in, and the hours it
/// normally occupies. These are what the chart draws as ghosts — outlines
/// you click to put a real shift there.
struct ShiftTemplate: Codable, Equatable, Identifiable {
    enum Slot: String, Codable, CaseIterable {
        case morning, afternoon, evening

        var label: String {
            switch self {
            case .morning: return "Morning"
            case .afternoon: return "Afternoon"
            case .evening: return "Evening"
            }
        }
    }

    var slot: Slot
    var startHour: Double
    var endHour: Double

    var id: Slot { slot }
    var hours: Double { max(0, endHour - startHour) }

    /// 9–12, 1–5, 6–10. Two of those make the seven-hour day the weekly
    /// target is built from; the evening is there for the days you work it.
    static let standard: [ShiftTemplate] = [
        ShiftTemplate(slot: .morning, startHour: 9, endHour: 12),
        ShiftTemplate(slot: .afternoon, startHour: 13, endHour: 17),
        ShiftTemplate(slot: .evening, startHour: 18, endHour: 22),
    ]
}

/// The user's configured work-schedule preferences — either set manually or
/// parsed from a free-text description via the on-device LLM (see
/// `WorkPreferencesGenerator`). Drives `WorkloadRecommender`'s weekly
/// target and the ghost shifts drawn on each day's bar.
struct WorkPreferences: Codable, Equatable {
    /// Seven hours a weekday. Seven rather than eight because lunch is no
    /// longer inside the number: the day is 9–12 and 1–5, and the hour
    /// between them is a gap rather than worked time that gets subtracted
    /// again later.
    var weeklyTargetHours: Double = 35
    var shifts: [ShiftTemplate] = ShiftTemplate.standard
    /// Desired meetings/day, if the person expressed one. Not yet consumed
    /// anywhere in the UI beyond being stored and shown back in the
    /// preferences editor — a natural follow-up would be comparing it
    /// against the actual per-week meeting average.
    var targetMeetingHoursPerDay: Double?
    /// Desired focused/deep-work hours/day, if the person expressed one.
    /// Same status as `targetMeetingHoursPerDay` above.
    var targetFocusHoursPerDay: Double?

    static let `default` = WorkPreferences()

    /// What the manual editor's controls offer, and what a schedule parsed
    /// from free text is held to. Kept here rather than in
    /// `WorkPreferencesForm` because the model is guided, not constrained,
    /// and can hand back a negative week or a 200-hour one: a value the
    /// pickers have no option for leaves them blank and unusable, so the
    /// two paths have to agree on the bounds rather than one of them
    /// knowing about them.
    static let weeklyTargetRange: ClosedRange<Double> = 5...80
    static let dailyHoursRange: ClosedRange<Double> = 0.5...8

    /// Half-hour steps, since that's the resolution `HoursFormat` displays.
    static let dailyHoursOptions: [Double] = Array(
        stride(from: dailyHoursRange.lowerBound, through: dailyHoursRange.upperBound, by: 0.5)
    )

    /// Rounds and clamps everything to what the editor can represent, and
    /// drops any shift that can't be drawn. Applied to whatever the
    /// on-device model produces before it becomes settings.
    func sanitized() -> WorkPreferences {
        var copy = self
        copy.weeklyTargetHours = weeklyTargetHours.rounded().clamped(to: Self.weeklyTargetRange)
        copy.targetMeetingHoursPerDay = targetMeetingHoursPerDay.map(Self.roundedDailyHours)
        copy.targetFocusHoursPerDay = targetFocusHoursPerDay.map(Self.roundedDailyHours)
        copy.shifts = Self.usableShifts(from: shifts)
        return copy
    }

    /// Shift hours rounded to the whole hours the editor's pickers offer —
    /// they tag whole hours, so a half past nine matches no option and
    /// leaves the control blank — and then dropped if the rounding left
    /// nothing to draw, or if the slot runs into one already taken.
    ///
    /// Dropped rather than repaired, since there's no telling which of the
    /// two hours was meant; a schedule left with none at all falls back to
    /// the standard three. Overlap matters as well as order: two ghosts
    /// drawn over each other are two click targets in the same place, and
    /// the one you get is whichever the hit test reaches first.
    private static func usableShifts(from shifts: [ShiftTemplate]) -> [ShiftTemplate] {
        var kept: [ShiftTemplate] = []
        for shift in shifts {
            let start = shift.startHour.rounded().clamped(to: 0...23)
            let end = shift.endHour.rounded().clamped(to: 1...24)
            guard end > start else { continue }
            guard !kept.contains(where: { start < $0.endHour && end > $0.startHour }) else { continue }
            kept.append(ShiftTemplate(slot: shift.slot, startHour: start, endHour: end))
        }
        return kept.isEmpty ? ShiftTemplate.standard : kept
    }

    private static func roundedDailyHours(_ hours: Double) -> Double {
        ((hours * 2).rounded() / 2).clamped(to: dailyHoursRange)
    }

    /// When the day starts: the first shift's start. What the morning
    /// intention reminder is scheduled against.
    var workdayStartHour: Double {
        shifts.first?.startHour ?? 9
    }

    /// When the day is done — not the last shift's end, but wherever the
    /// day's share of the weekly target runs out, filling the shifts in
    /// order. At the default settings that's seven hours: three in the
    /// morning, four in the afternoon, finishing at 5pm, with the evening
    /// shift left where it belongs, unasked for.
    var workdayEndHour: Double {
        var remaining = weeklyTargetHours / 5
        for shift in shifts {
            if remaining <= shift.hours {
                return shift.startHour + max(remaining, 0)
            }
            remaining -= shift.hours
        }
        return shifts.last?.endHour ?? 17
    }

    /// A plain-English sentence describing these settings, generated from
    /// the struct's fields — this is what `PreferencesView` shows in place
    /// of a form of Steppers, mirroring the free-text description that
    /// produced it (or that it defaults to before you've described one).
    var summarySentence: String {
        var parts = ["\(HoursFormat.string(weeklyTargetHours))/week"]
        parts.append(contentsOf: shifts.map {
            "\(Self.clockLabel($0.startHour))–\(Self.clockLabel($0.endHour))"
        })
        if let targetMeetingHoursPerDay {
            parts.append("\(HoursFormat.string(targetMeetingHoursPerDay)) meetings/day")
        }
        if let targetFocusHoursPerDay {
            parts.append("\(HoursFormat.string(targetFocusHoursPerDay)) focus/day")
        }
        return parts.joined(separator: ", ") + "."
    }

    /// "9am", "5pm", "12am" — also used to label the hour pickers in
    /// `WorkPreferencesForm`, so the manual editor and this sentence agree
    /// on how a time is written.
    static func clockLabel(_ hour: Double) -> String {
        let period = hour < 12 || hour == 24 ? "am" : "pm"
        let displayHour = hour == 0 || hour == 24 ? 12 : (hour > 12 ? hour - 12 : hour)
        return "\(Int(displayHour))\(period)"
    }

    private enum CodingKeys: String, CodingKey {
        case weeklyTargetHours, shifts, targetMeetingHoursPerDay, targetFocusHoursPerDay
        /// Pre-shift settings: one unbroken window, lunch included.
        case workdayStartHour, workdayEndHour
    }

    init(
        weeklyTargetHours: Double = 35,
        shifts: [ShiftTemplate] = ShiftTemplate.standard,
        targetMeetingHoursPerDay: Double? = nil,
        targetFocusHoursPerDay: Double? = nil
    ) {
        self.weeklyTargetHours = weeklyTargetHours
        self.shifts = shifts
        self.targetMeetingHoursPerDay = targetMeetingHoursPerDay
        self.targetFocusHoursPerDay = targetFocusHoursPerDay
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(weeklyTargetHours, forKey: .weeklyTargetHours)
        try container.encode(shifts, forKey: .shifts)
        try container.encodeIfPresent(targetMeetingHoursPerDay, forKey: .targetMeetingHoursPerDay)
        try container.encodeIfPresent(targetFocusHoursPerDay, forKey: .targetFocusHoursPerDay)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetMeetingHoursPerDay = try container.decodeIfPresent(Double.self, forKey: .targetMeetingHoursPerDay)
        targetFocusHoursPerDay = try container.decodeIfPresent(Double.self, forKey: .targetFocusHoursPerDay)
        let storedTarget = try container.decodeIfPresent(Double.self, forKey: .weeklyTargetHours) ?? 35

        if let stored = try container.decodeIfPresent([ShiftTemplate].self, forKey: .shifts), !stored.isEmpty {
            shifts = stored
            weeklyTargetHours = storedTarget
            return
        }

        // Settings written before shifts existed. Their one window becomes
        // a morning and an afternoon with an hour between, keeping the start
        // and end they chose, and an evening slot is offered after it.
        let legacyStart = try container.decodeIfPresent(Double.self, forKey: .workdayStartHour) ?? 9
        let legacyEnd = try container.decodeIfPresent(Double.self, forKey: .workdayEndHour) ?? 17
        (shifts, weeklyTargetHours) = Self.migrated(
            legacyStartHour: legacyStart,
            legacyEndHour: legacyEnd,
            legacyWeeklyTargetHours: storedTarget
        )
    }

    /// Turns a pre-shift window into shifts. The target comes down by an
    /// hour a day, because that hour is lunch and the figure used to
    /// include it — the same reason the standard day is seven hours and not
    /// eight. A window too short to hold a lunch break is left as one shift
    /// with its target untouched.
    static func migrated(
        legacyStartHour: Double,
        legacyEndHour: Double,
        legacyWeeklyTargetHours: Double
    ) -> (shifts: [ShiftTemplate], weeklyTargetHours: Double) {
        guard legacyEndHour - legacyStartHour >= 5 else {
            return (
                [ShiftTemplate(slot: .morning, startHour: legacyStartHour, endHour: legacyEndHour)],
                legacyWeeklyTargetHours
            )
        }
        var shifts = [
            ShiftTemplate(slot: .morning, startHour: legacyStartHour, endHour: legacyStartHour + 3),
            ShiftTemplate(slot: .afternoon, startHour: legacyStartHour + 4, endHour: legacyEndHour),
        ]
        // Only where the day leaves room for one after it. Clamping an
        // evening slot backwards to fit — a window ending at midnight would
        // have taken 11pm — put it on top of the afternoon, and two ghosts
        // drawn over each other are two click targets in the same place.
        let eveningStart = legacyEndHour + 1
        if eveningStart < 24 {
            shifts.append(ShiftTemplate(slot: .evening, startHour: eveningStart, endHour: min(eveningStart + 4, 24)))
        }
        return (shifts, max(legacyWeeklyTargetHours - 5, 5))
    }
}

/// Persists `WorkPreferences` as a single JSON blob in UserDefaults —
/// unlike `WorkHistoryStore`'s growing daily history, this is one small
/// struct that only ever has its latest value read, so UserDefaults is
/// simpler than a dedicated file.
enum WorkPreferencesStore {
    private static let key = "WorkPreferences.current"

    static func load(defaults: UserDefaults = .standard) -> WorkPreferences {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(WorkPreferences.self, from: data) else {
            return .default
        }
        return decoded
    }

    static func save(_ preferences: WorkPreferences, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
