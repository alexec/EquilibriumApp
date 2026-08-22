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

/// One calendar day's work, as up to three shifts (see `WorkShift`).
///
/// This used to be a single contiguous block with a break duration
/// subtracted from it. Shifts say the same thing more directly: the time
/// between them is the break, so a 9–12 / 1–5 day is seven hours rather
/// than eight-minus-an-hour, and nothing has to remember to subtract.
struct WorkdaySpan: Codable, Identifiable {
    var id: String { dayKey }
    let dayKey: String // "yyyy-MM-dd" in local time

    /// This day's shifts: sorted, never overlapping, at most
    /// `ShiftPlan.maximumShifts` of them. Empty for a day with no work on
    /// it at all — which is a real state, since a day can hold meetings and
    /// no tracked hours.
    var shifts: [WorkShift] = []

    /// When the day's work began and finished — its outer envelope, which
    /// is what meetings are clipped to and what "you finished at 8pm" is
    /// read from. Not the same as worked time once there's more than one
    /// shift: that's `hours`.
    var start: Date { shifts.first?.start ?? dayStart }
    var end: Date { shifts.last?.end ?? dayStart }

    /// Midnight at the top of this day, from `dayKey` — the stand-in for
    /// start/end on a day with no shifts, where there's no real time to
    /// name but callers still expect a date on the right day.
    var dayStart: Date {
        Self.dayKeyFormatter.date(from: dayKey) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    /// Minutes subtracted from worked hours for breaks (lunch, etc.), always
    /// a multiple of 30. Pre-shift days carried this; nothing sets it now,
    /// since a break is a gap between shifts, but stored history still holds
    /// values and they go on being honoured.
    var breakMinutes: Int = 0

    /// True if the user manually set this day's shifts, in which case
    /// automatic wake/sleep detection must never overwrite them.
    var isManual: Bool = false

    /// This workday's meetings, each with its own real start/end time.
    /// Populated from EventKit once calendar permission is granted: clipped
    /// to `start...end` for days with real work, or full-day for future week
    /// days that only hold calendar blocks so far. Empty may mean "no
    /// calendar access yet" or "genuinely zero meetings" — see
    /// `hasCalendarData` for which.
    var meetings: [MeetingBlock] = []

    /// Whether this day's calendar has actually been checked — distinct
    /// from `meetings.isEmpty`, which could mean either "not checked yet"
    /// or "checked, zero meetings." Set once `refreshMeetingData()`
    /// processes this day.
    var hasCalendarData: Bool = false

    /// Break minutes that couldn't be expressed as a gap between shifts:
    /// pre-shift history's auto-detected intra-day breaks, and gaps closed
    /// by `ShiftPlan.normalize` folding a day of four or more stretches down
    /// to three. Deducted from `effectiveHours`, since the gaps they stand
    /// for are inside a shift and would otherwise be counted as worked.
    var intraBreakMinutes: Int = 0

    /// Duration in minutes of the longest uninterrupted active stretch during
    /// the workday (sleep-gap-free run of the machine being awake).
    var longestStretchMinutes: Int = 0

    /// True when at least one intra-day gap of >= 30 min was detected.
    /// Serves as a signal that the user took a proper lunch/rest break.
    var hasLunchBreak: Bool = false

    /// Time actually spent working: the shifts added up. The gaps between
    /// them are already excluded by not being in any shift, which is why a
    /// standard 9–12 / 1–5 day comes to seven hours.
    var hours: Double {
        shifts.reduce(0) { $0 + $1.hours }
    }

    /// Worked hours less whatever break time is still hiding inside a shift
    /// (`intraBreakMinutes`, or a pre-shift day's manual `breakMinutes`).
    /// For a day whose shifts were set by hand these are both zero and this
    /// is simply `hours`.
    var effectiveHours: Double {
        max(0, hours - Double(deductedBreakMinutes) / 60.0)
    }

    /// Effective (break-adjusted) hours, always rounded up to the nearest
    /// whole hour, per user preference.
    var roundedUpHours: Int {
        Int(effectiveHours.rounded(.up))
    }

    /// Break minutes still deducted from worked time rather than shown as a
    /// gap. A hand-set break wins over an auto-detected one, as it always
    /// did; capped at the day's own length so a stale figure from before an
    /// edit can't drive the day negative.
    private var deductedBreakMinutes: Int {
        let raw = breakMinutes > 0 ? breakMinutes : intraBreakMinutes
        return min(max(raw, 0), Int((hours * 60.0).rounded()))
    }

    /// Everything between the start and end of the day that wasn't worked:
    /// the gaps between shifts, plus any break still folded inside one.
    /// This is what the week's caption means by "Nh of breaks a day".
    /// Summed in seconds and rounded once at the end, not per gap: these
    /// are real wake and sleep timestamps rather than whole minutes, and
    /// truncating each gap on its own lost most of a minute per break.
    var breakMinutesUsed: Int {
        var gapSeconds: TimeInterval = 0
        for (earlier, later) in zip(shifts, shifts.dropFirst()) {
            gapSeconds += max(0, later.start.timeIntervalSince(earlier.end))
        }
        return Int((gapSeconds / 60.0).rounded()) + deductedBreakMinutes
    }

    /// Total minutes across all meetings that fall inside a shift. Meetings
    /// are clipped per shift rather than to the day's envelope: time in the
    /// lunch gap isn't worked time, so counting a meeting there would let
    /// meeting hours exceed the hours they're a part of.
    var meetingMinutes: Int {
        meetings.reduce(0) { total, meeting in
            total + shifts.reduce(0) { shiftTotal, shift in
                let clippedStart = max(meeting.start, shift.start)
                let clippedEnd = min(meeting.end, shift.end)
                guard clippedStart < clippedEnd else { return shiftTotal }
                return shiftTotal + Int(clippedEnd.timeIntervalSince(clippedStart) / 60.0)
            }
        }
    }

    init(
        dayKey: String,
        shifts: [WorkShift] = [],
        breakMinutes: Int = 0,
        isManual: Bool = false,
        meetings: [MeetingBlock] = [],
        hasCalendarData: Bool = false,
        intraBreakMinutes: Int = 0,
        longestStretchMinutes: Int = 0,
        hasLunchBreak: Bool = false
    ) {
        self.dayKey = dayKey
        self.shifts = shifts
        self.breakMinutes = breakMinutes
        self.isManual = isManual
        self.meetings = meetings
        self.hasCalendarData = hasCalendarData
        self.intraBreakMinutes = intraBreakMinutes
        self.longestStretchMinutes = longestStretchMinutes
        self.hasLunchBreak = hasLunchBreak
    }

    /// `meetingsManuallyEdited` was one of these, written by days whose
    /// meeting blocks had been dragged about. Meetings are read-only now,
    /// so it has no key at all: an old file still loads — an unrecognised
    /// key is simply ignored — and the flag it carries goes for good the
    /// next time that day is written, which is the point, since while it
    /// was set no calendar refresh could touch the day.
    private enum CodingKeys: String, CodingKey {
        case dayKey, shifts, breakMinutes, isManual, meetings, hasCalendarData
        case intraBreakMinutes, longestStretchMinutes, hasLunchBreak
        /// Pre-shift history: one contiguous block per day, read on the way
        /// in and never written again.
        case start, end
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dayKey, forKey: .dayKey)
        try container.encode(shifts, forKey: .shifts)
        try container.encode(breakMinutes, forKey: .breakMinutes)
        try container.encode(isManual, forKey: .isManual)
        try container.encode(meetings, forKey: .meetings)
        try container.encode(hasCalendarData, forKey: .hasCalendarData)
        try container.encode(intraBreakMinutes, forKey: .intraBreakMinutes)
        try container.encode(longestStretchMinutes, forKey: .longestStretchMinutes)
        try container.encode(hasLunchBreak, forKey: .hasLunchBreak)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try container.decode(String.self, forKey: .dayKey)
        breakMinutes = try container.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? 0
        isManual = try container.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        meetings = try container.decodeIfPresent([MeetingBlock].self, forKey: .meetings) ?? []
        hasCalendarData = try container.decodeIfPresent(Bool.self, forKey: .hasCalendarData) ?? false
        intraBreakMinutes = try container.decodeIfPresent(Int.self, forKey: .intraBreakMinutes) ?? 0
        longestStretchMinutes = try container.decodeIfPresent(Int.self, forKey: .longestStretchMinutes) ?? 0
        hasLunchBreak = try container.decodeIfPresent(Bool.self, forKey: .hasLunchBreak) ?? false

        if let stored = try container.decodeIfPresent([WorkShift].self, forKey: .shifts) {
            shifts = stored
        } else {
            // A day written before shifts existed: its one block becomes one
            // shift, and its recorded break stays a deduction rather than
            // being invented as a gap at a time nobody measured.
            let legacyStart = try container.decodeIfPresent(Date.self, forKey: .start)
            let legacyEnd = try container.decodeIfPresent(Date.self, forKey: .end)
            if let legacyStart, let legacyEnd, legacyEnd > legacyStart {
                shifts = [WorkShift(start: legacyStart, end: legacyEnd)]
            } else {
                shifts = []
            }
        }
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()
}
