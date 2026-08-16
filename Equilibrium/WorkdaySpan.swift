import Foundation

/// A single calendar meeting, with its own real start/end time within the
/// workday — as opposed to the old `meetingMinutes: Int?` aggregate, this
/// preserves *when* each meeting happened, which is what makes it possible
/// to draw and drag individual blocks. Overlapping/back-to-back calendar
/// events are merged into one `MeetingBlock` before being stored (see
/// `MeetingCalculator`); a block can also be created or reshaped entirely
/// by hand.
struct MeetingBlock: Codable, Identifiable, Equatable {
    let id: UUID
    var start: Date
    var end: Date

    init(id: UUID = UUID(), start: Date, end: Date) {
        self.id = id
        self.start = start
        self.end = end
    }
}

/// A single contiguous work block for one calendar day.
struct WorkdaySpan: Codable, Identifiable {
    var id: String { dayKey }
    let dayKey: String // "yyyy-MM-dd" in local time
    /// Mutable (unlike the historical wake/sleep-derived fields) since the
    /// whole workday span is now directly drag-editable — see
    /// `WorkHistoryViewModel.updateWorkday(for:newStart:newEnd:)`.
    var start: Date
    var end: Date

    /// Minutes subtracted from worked hours for breaks (lunch, etc.), always
    /// a multiple of 30. Always 0 for automatically-detected spans; only
    /// settable via manual edit.
    var breakMinutes: Int = 0

    /// True if the user manually set this span, in which case automatic
    /// wake/sleep detection must never overwrite it.
    var isManual: Bool = false

    /// This workday's meetings, each with its own real start/end time.
    /// Populated from EventKit once calendar permission is granted: clipped
    /// to `start...end` for days with a real work span, or full-day for
    /// future week days that only hold calendar blocks so far. Empty may
    /// mean "no calendar access yet" or "genuinely zero meetings" — see
    /// `hasCalendarData` for which.
    var meetings: [MeetingBlock] = []

    /// Whether this day's calendar has actually been checked — distinct
    /// from `meetings.isEmpty`, which could mean either "not checked yet"
    /// or "checked, zero meetings." Set once `refreshMeetingData()`
    /// processes this day.
    var hasCalendarData: Bool = false

    /// True once any meeting on this day has been hand-dragged (resized or
    /// moved). While true, calendar refreshes leave `meetings` alone
    /// rather than overwriting your edits — see `WorkHistoryViewModel`'s
    /// `updateMeeting`/`resetMeetings`.
    var meetingsManuallyEdited: Bool = false

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
    /// count and fiery-day intensity, since breaks aren't worked time.
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

    /// Minutes of this span not counted as worked time — i.e. `hours` minus
    /// `effectiveHours`.
    var breakMinutesUsed: Int {
        Int((hours * 60.0).rounded()) - Int(effectiveHours * 60.0)
    }

    /// Total minutes across all meetings, clamped to this span's bounds
    /// (meetings are already expected to arrive pre-clipped, but this
    /// guards against a hand-dragged block being pulled outside it).
    var meetingMinutes: Int {
        meetings.reduce(0) { total, meeting in
            let clippedStart = max(meeting.start, start)
            let clippedEnd = min(meeting.end, end)
            guard clippedStart < clippedEnd else { return total }
            return total + Int(clippedEnd.timeIntervalSince(clippedStart) / 60.0)
        }
    }

    init(
        dayKey: String,
        start: Date,
        end: Date,
        breakMinutes: Int = 0,
        isManual: Bool = false,
        meetings: [MeetingBlock] = [],
        hasCalendarData: Bool = false,
        meetingsManuallyEdited: Bool = false,
        intraBreakMinutes: Int = 0,
        longestStretchMinutes: Int = 0,
        hasLunchBreak: Bool = false
    ) {
        self.dayKey = dayKey
        self.start = start
        self.end = end
        self.breakMinutes = breakMinutes
        self.isManual = isManual
        self.meetings = meetings
        self.hasCalendarData = hasCalendarData
        self.meetingsManuallyEdited = meetingsManuallyEdited
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
        meetings = try container.decodeIfPresent([MeetingBlock].self, forKey: .meetings) ?? []
        hasCalendarData = try container.decodeIfPresent(Bool.self, forKey: .hasCalendarData) ?? false
        meetingsManuallyEdited = try container.decodeIfPresent(Bool.self, forKey: .meetingsManuallyEdited) ?? false
        intraBreakMinutes = try container.decodeIfPresent(Int.self, forKey: .intraBreakMinutes) ?? 0
        longestStretchMinutes = try container.decodeIfPresent(Int.self, forKey: .longestStretchMinutes) ?? 0
        hasLunchBreak = try container.decodeIfPresent(Bool.self, forKey: .hasLunchBreak) ?? false
    }
}
