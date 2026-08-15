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

    /// Total minutes of calendar meeting time within this workday (all-day
    /// and free events excluded). Populated from EventKit after calendar
    /// permission is granted; nil when permission is denied or not yet
    /// determined.
    var meetingMinutes: Int? = nil

    /// Length (in minutes) of the longest contiguous meeting-free block
    /// within this workday. Populated alongside `meetingMinutes`.
    var longestFocusBlockMinutes: Int? = nil

    /// Raw duration from start to end, before subtracting breaks. This is
    /// what the chart's capsule renders (it spans the actual time present),
    /// independent of how much of that time was a break.
    var hours: Double {
        end.timeIntervalSince(start) / 3600.0
    }

    /// Worked hours after subtracting breaks — used for the displayed hour
    /// count and the over/under-8h color, since breaks aren't worked time.
    var effectiveHours: Double {
        max(0, hours - Double(breakMinutes) / 60.0)
    }

    /// Effective (break-adjusted) hours, always rounded up to the nearest
    /// whole hour, per user preference.
    var roundedUpHours: Int {
        Int(effectiveHours.rounded(.up))
    }

    /// Focus minutes: effective minutes minus meeting time.
    var focusMinutes: Int? {
        guard let meeting = meetingMinutes else { return nil }
        let effectiveMinutes = Int(effectiveHours * 60.0)
        return max(0, effectiveMinutes - meeting)
    }

    /// Meeting fraction (0–1) relative to effective hours, or nil when
    /// no calendar data is available.
    var meetingFraction: Double? {
        guard let meeting = meetingMinutes else { return nil }
        let effectiveMinutes = Int(effectiveHours * 60.0)
        guard effectiveMinutes > 0 else { return nil }
        return Double(min(meeting, effectiveMinutes)) / Double(effectiveMinutes)
    }

    init(dayKey: String, start: Date, end: Date, breakMinutes: Int = 0, isManual: Bool = false,
         meetingMinutes: Int? = nil, longestFocusBlockMinutes: Int? = nil) {
        self.dayKey = dayKey
        self.start = start
        self.end = end
        self.breakMinutes = breakMinutes
        self.isManual = isManual
        self.meetingMinutes = meetingMinutes
        self.longestFocusBlockMinutes = longestFocusBlockMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try container.decode(String.self, forKey: .dayKey)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        breakMinutes = try container.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? 0
        isManual = try container.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        meetingMinutes = try container.decodeIfPresent(Int.self, forKey: .meetingMinutes)
        longestFocusBlockMinutes = try container.decodeIfPresent(Int.self, forKey: .longestFocusBlockMinutes)
    }
}
