import Foundation

/// A single contiguous work block for one calendar day.
struct WorkdaySpan: Codable, Identifiable {
    var id: String { dayKey }
    let dayKey: String // "yyyy-MM-dd" in local time
    let start: Date
    let end: Date

    /// Minutes subtracted from worked hours for breaks (lunch, etc.), always
    /// a multiple of 30. Always 0 for automatically-detected spans; only
    /// settable via manual edit.
    var breakMinutes: Int = 0

    /// True if the user manually set this span, in which case automatic
    /// wake/sleep detection must never overwrite it.
    var isManual: Bool = false

    /// Break minutes automatically detected from intra-day sleep/wake gaps
    /// in the pmset log (gaps >= 20 min but < the 8 h new-day threshold).
    /// Used for `effectiveHours` when no manual `breakMinutes` override is set.
    var intraBreakMinutes: Int = 0

    /// Duration in minutes of the longest uninterrupted active stretch during
    /// the workday (sleep-gap-free run of the machine being awake).
    var longestStretchMinutes: Int = 0

    /// True when at least one intra-day gap of >= 30 min was detected.
    /// Serves as a signal that the user took a proper lunch/rest break.
    var hasLunchBreak: Bool = false

    /// Raw duration from start to end, before subtracting breaks. This is
    /// what the chart's capsule renders (it spans the actual time present),
    /// independent of how much of that time was a break.
    var hours: Double {
        end.timeIntervalSince(start) / 3600.0
    }

    /// Worked hours after subtracting breaks — used for the displayed hour
    /// count and the over/under-8h color, since breaks aren't worked time.
    /// If the user has set a manual `breakMinutes` override, that takes
    /// precedence; otherwise auto-detected `intraBreakMinutes` is used.
    var effectiveHours: Double {
        let deductMinutes = isManual ? breakMinutes : (breakMinutes > 0 ? breakMinutes : intraBreakMinutes)
        return max(0, hours - Double(deductMinutes) / 60.0)
    }

    /// Effective (break-adjusted) hours, always rounded up to the nearest
    /// whole hour, per user preference.
    var roundedUpHours: Int {
        Int(effectiveHours.rounded(.up))
    }

    init(
        dayKey: String,
        start: Date,
        end: Date,
        breakMinutes: Int = 0,
        isManual: Bool = false,
        intraBreakMinutes: Int = 0,
        longestStretchMinutes: Int = 0,
        hasLunchBreak: Bool = false
    ) {
        self.dayKey = dayKey
        self.start = start
        self.end = end
        self.breakMinutes = breakMinutes
        self.isManual = isManual
        self.intraBreakMinutes = intraBreakMinutes
        self.longestStretchMinutes = longestStretchMinutes
        self.hasLunchBreak = hasLunchBreak
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try container.decode(String.self, forKey: .dayKey)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        breakMinutes = try container.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? 0
        isManual = try container.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        intraBreakMinutes = try container.decodeIfPresent(Int.self, forKey: .intraBreakMinutes) ?? 0
        longestStretchMinutes = try container.decodeIfPresent(Int.self, forKey: .longestStretchMinutes) ?? 0
        hasLunchBreak = try container.decodeIfPresent(Bool.self, forKey: .hasLunchBreak) ?? false
    }
}
