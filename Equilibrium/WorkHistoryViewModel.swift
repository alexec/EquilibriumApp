import Foundation
import Combine

/// The two things recorded against a day: a morning intention and an
/// end-of-day check-in.
enum DailyPromptKind: Equatable {
    case intention
    case checkIn
}

/// How far the calendar permission has got. `pending` covers both "not
/// asked yet" and "prompt still on screen": from the app's side they're the
/// same wait, and both end when `requestAccess()` returns.
enum CalendarAccessState: Equatable {
    case pending
    case granted
    case denied
}

/// The day the side panel is editing, and which of its two sections asked
/// to be edited — the panel always shows both, so the kind only decides
/// where the keyboard focus lands.
struct DayEditorSelection: Equatable {
    let day: Date
    var kind: DailyPromptKind
}

@MainActor
final class WorkHistoryViewModel: ObservableObject {
    @Published var spansByDay: [String: WorkdaySpan] = [:]
    @Published var isLoading = false
    /// Where calendar access has got to. Three states rather than a flag
    /// because "not granted" covers two situations the UI shouldn't
    /// conflate: still waiting on the prompt, and told no.
    @Published var calendarAccess: CalendarAccessState = .pending
    /// Whether meetings can be read right now — the question most of this
    /// class asks, with the reason it can't left to the UI.
    var calendarAccessGranted: Bool { calendarAccess == .granted }
    /// LLM-generated "You worked ..." caption per week, keyed by that
    /// week's first day (`dayKey`). Falls back to a deterministic sentence
    /// (see `WeeklyInsightGenerator.WeekHeaderStats.fallbackSentence`)
    /// wherever a key is missing — model unavailable, or not generated yet.
    @Published var weekHeaderSummaries: [String: String] = [:]
    /// The user's configured work schedule — weekly target, workday span,
    /// and (optionally) meeting/focus targets. Set manually or parsed from
    /// free text via `WorkPreferencesGenerator`; see `PreferencesView`.
    @Published var preferences: WorkPreferences = WorkPreferencesStore.load()
    /// Per-day morning intentions + evening check-ins.
    @Published var intentionsByDay: [String: DailyIntention] = [:]
    /// Today's meetings with their titles, kept here so the menu bar can
    /// name the next one without a calendar query on every redraw.
    @Published private(set) var todaysMeetings: [DayMeeting] = []
    /// Spoken form of the same line, which spells out the meeting's full
    /// title: the menu bar truncates for space, VoiceOver has no such
    /// problem and every reason to say the whole thing.
    @Published private(set) var menuBarAccessibilityLabel: String = ""
    /// What the menu bar reads, as a finished string.
    ///
    /// Published rather than computed in the view because a `MenuBarExtra`
    /// label doesn't follow an observed object: a child view built there is
    /// rendered once and keeps whatever it was first given — today's
    /// meetings arrive a second later and never showed up. Publishing the
    /// text puts the change in the App's own body, which does get rebuilt.
    @Published private(set) var menuBarText: String = ""
    /// LLM phrase describing a day's meetings, keyed by `dayKey`. Missing
    /// wherever the model is unavailable or hasn't answered yet — the panel
    /// shows the count and hours regardless.
    @Published var meetingGists: [String: String] = [:]

    /// The inbox, newest first, as of the last trip to Mail.
    @Published private(set) var mailMessages: [MailMessage] = []
    /// One summary per message id, seeded from disk at launch so a relaunch
    /// shows yesterday's conclusions immediately instead of an empty column
    /// while the model works through them again.
    @Published private(set) var mailSummaries: [String: MailSummary] = [:]
    @Published private(set) var mailAccess: MailAccessState = .pending
    /// The two-sentence "what today asks of you" above the inbox. Nil until
    /// there's one worth showing; the column falls back to counts.
    @Published private(set) var dayBrief: String?
    /// Every address configured in Mail — used to leave you out of your own
    /// people list.
    @Published private(set) var myAddresses: Set<String> = []
    /// Who you're working with, and the counts under the brief.
    ///
    /// Stored rather than computed on demand, because both are read from
    /// `ContentView`'s body and both are expensive: `meetings(for:)` runs an
    /// EventKit query every time it's called, and SwiftUI calls a body far
    /// more often than the underlying data changes. Recomputed from
    /// `refreshDerivedMailState()` whenever something they depend on moves.
    @Published private(set) var currentPeople: [PersonActivity] = []
    @Published private(set) var dayBriefFallback: String = ""
    /// Why the last archive didn't happen, when it didn't.
    @Published private(set) var archiveProblem: String?
    /// Why the last meeting deletion didn't happen, when it didn't.
    @Published private(set) var meetingDeleteProblem: String?
    /// When each deferred message should come back, by message id. Read
    /// from Reminders rather than owned here.
    @Published private(set) var mailDeferrals: [String: Date] = [:]
    /// Why the last deferral didn't happen, when it didn't.
    @Published private(set) var deferProblem: String?
    /// Whether the column is currently showing what's been deferred away.
    @Published var showsDeferred = false
    /// Whether the preferences sheet is up.
    ///
    /// Lives here rather than in `ContentView`'s `@State` because the thing
    /// that opens it is now a menu command, and a `Commands` builder can't
    /// reach into a view's private state.
    @Published var showsPreferences = false
    /// The day shown in the panel beside the chart. Always set — the panel
    /// is permanent furniture rather than something you open — so this
    /// starts on today and only ever moves to another day.
    @Published var dayEditor = DayEditorSelection(day: Calendar.current.startOfDay(for: Date()), kind: .intention)
    /// Calendars offered by the preferences picker. Empty until calendar
    /// access is granted, since EventKit vends nothing before then.
    @Published var availableCalendars: [SelectableCalendar] = []
    /// Which calendar is read, or `nil` while the user hasn't picked one.
    @Published var calendarSelection: String?
    /// Mail accounts for the picker, and the chosen one.
    @Published var mailAccounts: [SelectableMailAccount] = []
    @Published var mailSelection: String?
    /// Which mailbox the messages on screen actually came from. Published
    /// so the picker can own up to a fallback: an account that can't be
    /// opened means the column is showing every account's mail, and the
    /// only thing worse than that is not saying so.
    @Published private(set) var mailScope: MailScope = .allAccounts
    /// Which week the chart shows, counted from the current one: 0 is this
    /// week, -1 last week. The chart is deliberately one week at a time —
    /// the week is the unit everything else here works in (the target, the
    /// recommendation, the weekly summary) — so history is reached by
    /// paging rather than by widening the window.
    @Published private(set) var weekOffset: Int = 0

    private let store = WorkHistoryStore()
    private let intentionStore = DailyIntentionStore()
    private let liveEventStore = LiveEventStore()
    private let mailSummaryStore = MailSummaryStore()
    private let calendar: Calendar = .current
    private var autoRefreshTimer: Timer?
    private var menuBarTimer: Timer?
    private lazy var powerMonitor: PowerNotificationMonitor = {
        PowerNotificationMonitor { [weak self] event in
            Task { @MainActor in
                self?.handleLiveEvent(event)
            }
        }
    }()

    private static let autoRefreshInterval: TimeInterval = 5 * 60

    init() {
        // Both stores are read here so the first paint already has the
        // week's bars and its intentions. The refresh that follows sits
        // behind `await CalendarStore.requestAccess()`, which can take
        // seconds — or, seen in practice, not come back at all — and
        // loading only there left the chart looking like a machine with no
        // history rather than one waiting on a permission.
        spansByDay = store.load()
        intentionsByDay = intentionStore.load()
        calendarSelection = CalendarStore.shared.selection
        mailSummaries = mailSummaryStore.load()
        mailSelection = MailStore.shared.selection
        // Built here so the menu bar has its figure from the first draw.
        // Everything else that sets it waits on calendar access, which can
        // take a while — or never come back — and the label would have sat
        // there empty until it did.
        refreshMenuBarText()
    }

    /// The `WeekHeaderStats` each week's summary was last generated from,
    /// so an unchanged week doesn't re-invoke the model on every refresh.
    private var lastWeekHeaderStats: [String: WeeklyInsightGenerator.WeekHeaderStats] = [:]
    /// The meetings each day's gist was generated from, same idea.
    private var lastGistMeetings: [String: String] = [:]
    /// What the day brief was last written from, so the second pass doesn't
    /// re-run on every five-minute tick that changed nothing.
    private var lastBriefSignature: String?
    /// Addresses the calendar says are you, gathered once per refresh
    /// rather than per day selection.
    private var calendarSelfAddresses: Set<String> = []
    /// Every meeting in the week on screen, for the people strip. Cached
    /// because gathering it is seven EventKit queries and the strip is
    /// rebuilt on every day click.
    private var weekMeetings: [DayMeeting] = []
    /// Whether a trip to Mail is under way, so a second one doesn't start
    /// on top of it — the model pass alone takes seconds per message.
    private var isRefreshingMail = false
    /// Whether a refresh was asked for while one was already running, so
    /// the running one goes round again instead of the request being lost.
    /// See `refreshMail`.
    private var mailRefreshQueued = false

    private let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    /// Requests calendar access and kicks off the first data refresh.
    func requestCalendarAccessAndRefresh() async {
        calendarAccess = await CalendarStore.shared.requestAccess() ? .granted : .denied
        if calendarAccessGranted {
            availableCalendars = CalendarStore.shared.availableCalendars()
        }
        refresh()
        // The day the panel opens on never goes through `selectDay`, and
        // until access resolves there are no meetings to describe anyway —
        // so this is the first moment today's summary can be asked for.
        refreshMeetingGist()
        refreshTodaysMeetings()
    }

    /// Records a new calendar choice and re-reads meeting data so days
    /// annotated from a no-longer-selected calendar drop their meetings
    /// immediately, rather than lingering until the next auto-refresh.
    func updateCalendarSelection(_ identifier: String?) {
        CalendarStore.shared.updateSelection(identifier)
        calendarSelection = identifier
        guard calendarAccessGranted else { return }
        Task { await refreshMeetingData() }
    }

    /// Starts IOKit power-notification monitoring and the periodic refresh
    /// timers. Safe to call more than once.
    ///
    /// Called once, from the App's own `init`, and never stopped — the
    /// timers live as long as the process rather than as long as a window.
    /// This used to be driven from `ContentView`'s `onAppear`/`onDisappear`
    /// pair, which was wrong twice over. The obvious way: closing the
    /// window on a menu bar app is the normal thing to do, and it silently
    /// took the menu bar's line, the five-minute data refresh and the power
    /// monitor with it, so the tray sat on whatever figure it happened to
    /// be showing and the sleep/wake events behind the whole app stopped
    /// being recorded — measured at zero ticks in the half-minute after the
    /// close, against one every interval before it. The less obvious way:
    /// SwiftUI brings up two windows of the group at launch and
    /// `WindowChromeRemover` closes the spare, so an `onDisappear` fires
    /// seconds after `onAppear` with nobody having closed anything, and
    /// whether the timers survived it came down to which order the two
    /// windows happened to run their callbacks in.
    ///
    /// There is deliberately no `stopAutoRefresh` counterpart. Nothing in a
    /// menu bar app should be able to switch the menu bar off, and an
    /// unused one is an invitation to wire it back to a window.
    func startAutoRefresh() {
        powerMonitor.start()
        guard autoRefreshTimer == nil else { return }
        let dataTimer = Timer(timeInterval: Self.autoRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                await self?.refreshMail()
            }
        }
        // A minute, not five: the menu bar's line moves on its own as the
        // day passes — the figure counts down, and a meeting drops off the
        // moment it ends — without any of the data behind it changing.
        let statusTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Re-reads the diary, not just the clock: a meeting moved or
                // added shows up within the minute, and the day's own
                // meetings are re-fetched after midnight rather than the app
                // naming yesterday's.
                self?.refreshTodaysMeetings()
            }
        }
        // `.common` rather than the `.default` mode `scheduledTimer` would
        // have used. The moment the menu bar's line is actually being read
        // is the moment its menu is open, and that puts the run loop into
        // event tracking — where a default-mode timer doesn't fire at all.
        // The five-minute one joins it for the same reason in miniature:
        // dragging the window's edge shouldn't pause the app's data.
        RunLoop.main.add(dataTimer, forMode: .common)
        RunLoop.main.add(statusTimer, forMode: .common)
        autoRefreshTimer = dataTimer
        menuBarTimer = statusTimer
    }

    func refresh() {
        spansByDay = store.load()
        isLoading = true
        // Captured before entering the detached task: reading the @Published
        // property from off the main actor would be a data race.
        let granted = calendarAccessGranted
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Live events captured by IOKit and persisted across launches.
            // This is the only wake/sleep source: the sandbox rules out
            // shelling out to `pmset -g log` for historical backfill.
            let liveEvents = self.liveEventStore.load()
            let freshSpans = WorkdayCalculator.computeSpans(from: liveEvents, calendar: Calendar.current)

            await MainActor.run { [weak self] in
                guard let self else { return }
                let today = self.dayKey(for: Date())
                let yesterday = self.dayKey(for: self.calendar.date(byAdding: .day, value: -1, to: Date())!)
                self.spansByDay = self.store.merge(freshSpans: freshSpans, today: today, yesterday: yesterday)
                self.isLoading = false
                self.refreshMenuBarText()
                WeeklySummaryNotifier.fireIfNeeded(store: self.store, weeklyTargetHours: self.preferences.weeklyTargetHours)
                self.refreshWeekHeaderSummaries()
            }

            // Annotate spans with meeting data when calendar access is available.
            if granted {
                await self.refreshMeetingData()
            }
        }
    }

    /// Regenerates the LLM "You worked ..." caption for the week the chart
    /// is currently showing. Skips the work when that week's
    /// `WeekHeaderStats` haven't changed since the last generation, so an
    /// unchanged week doesn't re-invoke the model on every 5-minute auto
    /// refresh — and so paging back and forth through weeks reuses what's
    /// already been generated rather than asking again. Silently does
    /// nothing if Foundation Models isn't available.
    func refreshWeekHeaderSummaries() {
        guard WeeklyInsightGenerator.isAvailable else { return }
        guard #available(macOS 26.0, *) else { return }

        let week = visibleWeekDays
        guard let first = week.first else { return }
        let key = dayKey(for: first)

        guard let stats = WeeklyInsightGenerator.WeekHeaderStats.compute(
            from: week.map { span(for: $0) },
            weeklyTargetHours: preferences.weeklyTargetHours
        ) else {
            lastWeekHeaderStats[key] = nil
            weekHeaderSummaries[key] = nil
            return
        }
        guard lastWeekHeaderStats[key] != stats else { return }
        lastWeekHeaderStats[key] = stats

        Task {
            let summary = await WeeklyInsightGenerator.generateWeekHeaderSummary(for: stats)
            // Generation takes seconds, and the week's figures can change
            // while it runs — an edited day, an auto-refresh. If they have,
            // a newer generation is already under way and this sentence
            // describes numbers the bars no longer show, so it's dropped
            // rather than left on screen until the figures next change.
            guard lastWeekHeaderStats[key] == stats else { return }
            weekHeaderSummaries[key] = summary
        }
    }

    /// The LLM-generated caption for the week starting on `day`, or nil if
    /// unavailable/not yet generated — callers should fall back to
    /// `WeeklyInsightGenerator.WeekHeaderStats.fallbackSentence`.
    func weekHeaderSummary(forWeekStarting day: Date) -> String? {
        weekHeaderSummaries[dayKey(for: day)]
    }

    /// Re-reads calendar events for every stored day (clipped to the workday
    /// span when there is one, full-day otherwise) and for remaining days in
    /// the current week, so future days without a work capsule still show
    /// meetings. Days with hand-dragged meetings (`meetingsManuallyEdited`)
    /// are left alone — see `updateMeeting`.
    ///
    /// Zero-hour days are re-read too, not just worked ones. They can hold
    /// meetings (a day full of calls but no tracked activity), and if they
    /// were skipped their meetings would be frozen forever — most visibly
    /// after deselecting a calendar in preferences, where its events would
    /// linger on exactly those days.
    @MainActor
    func refreshMeetingData() async {
        var updated = spansByDay
        let today = calendar.startOfDay(for: Date())

        for (key, span) in spansByDay {
            guard !span.meetingsManuallyEdited else { continue }
            guard let date = dayKeyFormatter.date(from: key) else { continue }

            // Clip to the workday only when one was actually tracked;
            // a zero-hour day would clip every meeting away to nothing.
            let hasWorkday = !span.shifts.isEmpty
            let events = hasWorkday
                ? CalendarStore.shared.meetingEvents(on: date, span: span)
                : CalendarStore.shared.meetingEvents(on: date)
            let meetings = hasWorkday
                ? MeetingCalculator.mergedBlocks(from: events, clippedTo: span)
                : MeetingCalculator.mergedBlocks(from: events)

            // A zero-hour day whose meetings have all gone carries nothing
            // worth keeping, so drop the row rather than leaving an empty
            // placeholder bar. Manual overrides are the exception: the user
            // put that day there deliberately.
            //
            // Only today onward, matching the current-week pass below.
            // Nothing ever re-scans a past date that isn't already stored,
            // so dropping one would be permanent — re-selecting a calendar
            // in preferences could never bring that day back. Past days keep
            // their (now empty) row instead, which renders the same as no row.
            if meetings.isEmpty, !hasWorkday, !span.isManual, date >= today {
                updated.removeValue(forKey: key)
                continue
            }

            var annotated = span
            annotated.meetings = meetings
            annotated.hasCalendarData = true
            updated[key] = annotated
        }

        // Current week from today onward: always surface calendar meetings,
        // even when there's no workday yet (start == end → 0h placeholder).
        for date in currentWeekDays() where date >= today {
            let key = dayKey(for: date)
            if let existing = updated[key], !existing.shifts.isEmpty { continue }
            if let existing = updated[key], existing.meetingsManuallyEdited { continue }

            let events = CalendarStore.shared.meetingEvents(on: date)
            let meetings = MeetingCalculator.mergedBlocks(from: events)
            // Don't invent empty history rows for days with nothing on the
            // calendar; drop a prior 0h holder once its meetings clear.
            if meetings.isEmpty {
                if let existing = updated[key], existing.shifts.isEmpty, !existing.isManual {
                    updated.removeValue(forKey: key)
                }
                continue
            }

            var span = updated[key] ?? WorkdaySpan(dayKey: key)
            span.meetings = meetings
            span.hasCalendarData = true
            updated[key] = span
        }

        spansByDay = updated
        // Persist updated spans so meeting data survives across launches.
        store.save(updated)
        // Meeting data just landed, which affects what the week summaries
        // describe — refresh those that changed.
        refreshWeekHeaderSummaries()
        refreshMeetingGist()
        refreshTodaysMeetings()
        reloadWeekMeetings()
        refreshDerivedMailState()
    }

    /// Drag-clamp bounds for a meeting: the workday when one exists,
    /// otherwise the chart's 6am–midnight window for that calendar day.
    private func meetingClampBounds(for span: WorkdaySpan, on date: Date) -> (Date, Date) {
        if !span.shifts.isEmpty {
            return (span.start, span.end)
        }
        let startOfDay = calendar.startOfDay(for: date)
        let start = calendar.date(
            bySettingHour: Int(ChartScale.startHour), minute: 0, second: 0, of: startOfDay
        ) ?? startOfDay
        let end = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        return (start, end)
    }

    /// Handles a live IOKit power event: persists it and triggers a refresh
    /// so the current-day bar updates immediately.
    private func handleLiveEvent(_ event: PowerEvent) {
        liveEventStore.append([event])
        refresh()
    }

    private func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    func span(for date: Date) -> WorkdaySpan? {
        spansByDay[dayKey(for: date)]
    }

    /// Permanently blanks out a day's hours (0h), protected like any other
    /// manual override so automatic refreshes never repopulate it.
    ///
    /// Deliberately the same path as removing the day's last shift by hand,
    /// since it leaves the day in the same state: what's deleted is the
    /// hours, and the day's meetings are no business of the trash button.
    /// Building a fresh empty span here instead threw them away, and left
    /// the two routes to an empty day disagreeing about it.
    func deleteHours(for date: Date) {
        setShifts(for: date, [])
    }

    /// Adds a shift to a day — from clicking one of its ghost outlines, or
    /// drawing one from scratch on the column. A shift that touches or
    /// overlaps one already there merges with it rather than becoming a
    /// fourth block; a day already holding `ShiftPlan.maximumShifts`
    /// separate shifts takes no more.
    func addShift(for date: Date, start: Date, end: Date) {
        guard start < end else { return }
        let existing = spansByDay[dayKey(for: date)]?.shifts ?? []
        let touchesExisting = existing.contains { $0.start <= end && $0.end >= start }
        guard touchesExisting || existing.count < ShiftPlan.maximumShifts else { return }
        setShifts(for: date, existing + [WorkShift(start: start, end: end)])
    }

    /// Reshapes one shift — from dragging its top edge (start), bottom edge
    /// (end), or middle (move) on the day bar. Dragged onto a neighbour,
    /// the two come back as one.
    func updateShift(for date: Date, shiftID: UUID, start: Date, end: Date) {
        guard start < end else { return }
        guard let span = spansByDay[dayKey(for: date)] else { return }
        guard span.shifts.contains(where: { $0.id == shiftID }) else { return }
        setShifts(for: date, span.shifts.map { shift in
            shift.id == shiftID ? WorkShift(id: shift.id, start: start, end: end) : shift
        })
    }

    /// Removes one shift, leaving the rest of the day alone — the ghost
    /// that outline came from reappears in its place.
    func removeShift(for date: Date, shiftID: UUID) {
        guard let span = spansByDay[dayKey(for: date)] else { return }
        setShifts(for: date, span.shifts.filter { $0.id != shiftID })
    }

    /// The one way a day's shifts are written. Normalises them (sorted,
    /// merged on contact, folded to at most three), then marks the day
    /// `isManual` — the same flag that already protects hand-set days from
    /// automatic wake/sleep recompute — so the edit sticks.
    ///
    /// Auto-detected break minutes are dropped: once the shifts are set by
    /// hand they say where the breaks were, and a figure measured against
    /// the day's earlier shape would go on being deducted from a day that
    /// no longer has that shape. What `normalize` had to fold back in is
    /// kept, since that time really is inside a shift without having been
    /// worked.
    ///
    /// Meetings are refetched immediately against the new shape when
    /// calendar access is granted and they haven't been hand-edited, rather
    /// than waiting for the next auto-refresh.
    private func setShifts(for date: Date, _ shifts: [WorkShift]) {
        let key = dayKey(for: date)
        var span = spansByDay[key] ?? WorkdaySpan(dayKey: key)
        let (normalized, absorbedGapMinutes) = ShiftPlan.normalize(shifts)
        span.shifts = normalized
        span.breakMinutes = 0
        span.intraBreakMinutes = absorbedGapMinutes
        if calendarAccessGranted, !span.meetingsManuallyEdited {
            // Clipping only applies where there's something to clip to:
            // through the last shift being removed, the day still shows the
            // meetings it holds rather than losing them to an empty window.
            if span.shifts.isEmpty {
                span.meetings = MeetingCalculator.mergedBlocks(from: CalendarStore.shared.meetingEvents(on: date))
            } else {
                let events = CalendarStore.shared.meetingEvents(on: date, span: span)
                span.meetings = MeetingCalculator.mergedBlocks(from: events, clippedTo: span)
            }
            span.hasCalendarData = true
        }
        spansByDay = store.setManualSpan(span)
        refreshWeekHeaderSummaries()
    }

    /// Updates one meeting's start/end — from dragging its top edge, bottom
    /// edge, or body on the day bar — clamped within that day's workday, or
    /// the chart window when there's no workday yet. Marks the day
    /// `meetingsManuallyEdited` so the next calendar refresh doesn't
    /// overwrite the edit. Start/end/break are untouched.
    func updateMeeting(for date: Date, meetingID: UUID, newStart: Date, newEnd: Date) {
        let key = dayKey(for: date)
        guard var span = spansByDay[key] else { return }
        guard let index = span.meetings.firstIndex(where: { $0.id == meetingID }) else { return }

        let (boundStart, boundEnd) = meetingClampBounds(for: span, on: date)
        let clampedStart = min(max(newStart, boundStart), boundEnd)
        let clampedEnd = min(max(newEnd, boundStart), boundEnd)
        guard clampedStart < clampedEnd else { return }

        span.meetings[index].start = clampedStart
        span.meetings[index].end = clampedEnd
        span.meetingsManuallyEdited = true
        spansByDay[key] = span
        store.save(spansByDay)
        refreshWeekHeaderSummaries()
    }

    /// Removes one meeting from a day — a meeting that was in the diary but
    /// didn't happen, or one the calendar holds twice.
    ///
    /// Marks the day `meetingsManuallyEdited` for the same reason
    /// `updateMeeting` does, and more sharply: without it the next calendar
    /// refresh would put the block straight back and the deletion would
    /// look broken. `resetMeetings` is the way back.
    func removeMeeting(for date: Date, meetingID: UUID) {
        let key = dayKey(for: date)
        guard var span = spansByDay[key] else { return }
        guard span.meetings.contains(where: { $0.id == meetingID }) else { return }

        span.meetings.removeAll { $0.id == meetingID }
        span.meetingsManuallyEdited = true
        spansByDay[key] = span
        store.save(spansByDay)
        refreshWeekHeaderSummaries()
    }

    /// Clears manual meeting edits for a day and immediately re-fetches
    /// from the calendar, reverting to calendar-derived meeting blocks.
    func resetMeetings(for date: Date) {
        let key = dayKey(for: date)
        guard var span = spansByDay[key] else { return }
        span.meetingsManuallyEdited = false
        if !span.shifts.isEmpty {
            let events = CalendarStore.shared.meetingEvents(on: date, span: span)
            span.meetings = MeetingCalculator.mergedBlocks(from: events, clippedTo: span)
        } else {
            let events = CalendarStore.shared.meetingEvents(on: date)
            span.meetings = MeetingCalculator.mergedBlocks(from: events)
        }
        span.hasCalendarData = true
        spansByDay[key] = span
        store.save(spansByDay)
        refreshWeekHeaderSummaries()
    }

    /// The week the chart is showing: a full Sat-Fri range (European-style
    /// weeks: Sat, Sun, Mon, Tue, Wed, Thu, Fri), including future days.
    var visibleWeekDays: [Date] {
        WeekCalendar.weekDays(offset: weekOffset, calendar: calendar)
    }

    /// How a week is named in the chart's navigation: the two most recent
    /// weeks get a relative name, since that's how you'd refer to them;
    /// older ones get their date range.
    ///
    /// Takes the week rather than deriving its own, so the name always
    /// describes the bars actually on screen. Deriving it here would mean a
    /// second reading of "now", which around midnight can land in a
    /// different week from the one the chart drew.
    func weekLabel(for week: [Date]) -> String {
        switch weekOffset {
        case 0: return "This week"
        case -1: return "Last week"
        default:
            guard let first = week.first, let last = week.last else { return "" }
            let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
            let end = sameMonth ? Self.dayOnlyFormatter : Self.monthDayFormatter
            return "\(Self.monthDayFormatter.string(from: first)) – \(end.string(from: last))"
        }
    }

    // Built once and reused: SwiftUI reads `weekLabel(for:)` on every pass
    // over the chart's body, and a DateFormatter is expensive enough that
    // constructing two per read is worth avoiding. Confined to the main
    // actor with the rest of the class, so sharing them is safe.
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let dayOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    /// Paging back stops at the week holding the oldest day on record —
    /// there's nothing before it but empty charts.
    var canShowPreviousWeek: Bool {
        guard let earliest = spansByDay.keys.min(), let earliestDay = dayKeyFormatter.date(from: earliest) else {
            return false
        }
        return earliestDay < WeekCalendar.weekStart(offset: weekOffset, calendar: calendar)
    }

    /// Paging forward stops at the current week; there's no data ahead of it.
    var canShowNextWeek: Bool { weekOffset < 0 }

    func showPreviousWeek() {
        guard canShowPreviousWeek else { return }
        weekOffset -= 1
        moveSelectionWithWeek(days: -7)
        refreshWeekHeaderSummaries()
        reloadWeekPeople()
    }

    func showNextWeek() {
        guard canShowNextWeek else { return }
        weekOffset += 1
        moveSelectionWithWeek(days: 7)
        refreshWeekHeaderSummaries()
        reloadWeekPeople()
    }

    /// Keeps the panel on the week the chart is showing, landing on the same
    /// weekday: paging back from Monday shows the Monday before it. Without
    /// this the panel would sit on a day that isn't among the bars beside
    /// it, its highlighted column nowhere on screen.
    /// Paging to another week changes whose meetings the strip is drawn
    /// from, so it's re-read here rather than left showing last week's.
    private func reloadWeekPeople() {
        reloadWeekMeetings()
        refreshDerivedMailState()
    }

    private func moveSelectionWithWeek(days: Int) {
        guard let moved = calendar.date(byAdding: .day, value: days, to: dayEditor.day) else { return }
        // Paging forward can land past today, which has no check-in to make;
        // the panel handles that by hiding the section, so only the day moves.
        dayEditor = DayEditorSelection(day: moved, kind: dayEditor.kind)
    }

    /// This week's full Saturday-through-Friday range, including future days.
    func currentWeekDays() -> [Date] {
        WeekCalendar.currentWeekDays(calendar: calendar)
    }

    /// Recommended hours to work on `date` toward the configured weekly
    /// target, or nil if `date` isn't a remaining, unworked weekday in the
    /// current week.
    func recommendedHours(for date: Date) -> Double? {
        WorkloadRecommender.recommendedHours(
            for: date,
            week: currentWeekDays(),
            today: calendar.startOfDay(for: Date()),
            weeklyTargetHours: preferences.weeklyTargetHours,
            hoursWorked: { [weak self] day in self?.span(for: day)?.effectiveHours ?? 0 },
            calendar: calendar
        )
    }

    /// Hours still to work today: today's share of what the week has left,
    /// less what today has already had. It counts down as the day is
    /// worked, reaches zero when today's share is used up, and asks for
    /// nothing at the weekend.
    ///
    /// Today's own hours are held back from the share and subtracted at the
    /// end rather than folded into the week's total: spread across the days
    /// still to come — today among them — a full day's work would come back
    /// as a fifth of itself still to do, and the figure would never reach
    /// zero.
    ///
    /// Deliberately not `WorkloadRecommender.recommendedHours(for:)`, which
    /// answers a different question — what an untouched day should hold —
    /// and stops answering at all once a day has any hours on it. The menu
    /// bar needs a figure that counts down while you work.
    func remainingHoursToday() -> Double {
        let today = calendar.startOfDay(for: Date())
        guard !WeekCalendar.isWeekend(today, calendar: calendar) else { return 0 }

        let week = currentWeekDays()
        let workedToday = span(for: today)?.effectiveHours ?? 0
        let workedEarlier = week
            .filter { $0 < today }
            .reduce(0.0) { $0 + (span(for: $1)?.effectiveHours ?? 0) }

        let daysLeft = week.filter {
            !WeekCalendar.isWeekend($0, calendar: calendar) && $0 >= today
        }.count
        guard daysLeft > 0 else { return 0 }

        let share = (preferences.weeklyTargetHours - workedEarlier) / Double(daysLeft)
        return max(share - workedToday, 0)
    }

    /// Hours worked this week subtracted from the configured weekly target.
    /// Positive means hours remain; negative means already over budget.
    func remainingWeeklyHours() -> Double {
        let week = currentWeekDays()
        let worked = week.reduce(0.0) { $0 + (span(for: $1)?.effectiveHours ?? 0) }
        return preferences.weeklyTargetHours - worked
    }

    /// Updates and persists the user's work-schedule preferences.
    func updatePreferences(_ new: WorkPreferences) {
        preferences = new
        WorkPreferencesStore.save(new)
        DailyIntentionNotifier.reschedule(preferences: new)
    }

    // MARK: - Daily intention / check-in

    /// A day's intention / check-in, for any day — the chart's buttons and
    /// the panel both work on whichever day you click, not just today.
    func intention(for day: Date) -> DailyIntention? {
        intentionsByDay[dayKey(for: day)]
    }

    /// Whether a meeting is happening now or still to come, since the menu
    /// bar has to say which: a meeting that started at 8:35 and runs to
    /// 10:00 is the one you're in at 9:25, and showing its start time reads
    /// as a stale "next".
    enum MeetingStanding: Equatable {
        case now
        case next
    }

    /// The meeting the menu bar should name: the one in progress if there is
    /// one, otherwise the next to start. Nil when the calendar can't be read
    /// or the day's meetings are all behind you.
    ///
    /// Read from the cached list rather than from EventKit, so it can be
    /// asked for as often as a view cares to draw.
    var currentOrNextMeeting: (meeting: DayMeeting, standing: MeetingStanding)? {
        let now = Date()
        if let inProgress = todaysMeetings.first(where: { $0.start <= now && $0.end > now }) {
            return (inProgress, .now)
        }
        if let upcoming = todaysMeetings.first(where: { $0.start > now }) {
            return (upcoming, .next)
        }
        return nil
    }

    /// Today's meetings that haven't finished — the one in progress first,
    /// then everything still to come. What the menu bar's panel lists.
    var remainingMeetingsToday: [DayMeeting] {
        let now = Date()
        return todaysMeetings.filter { $0.end > now }
    }

    /// Whether this meeting is happening right now.
    func isInProgress(_ meeting: DayMeeting) -> Bool {
        let now = Date()
        return meeting.start <= now && meeting.end > now
    }

    /// A day's calendar meetings with titles, for the panel's list. Past
    /// days work as well as today: EventKit keeps the events, so a day
    /// being edited weeks later still shows what was in the diary.
    func meetings(for day: Date) -> [DayMeeting] {
        guard calendarAccessGranted else { return [] }
        return CalendarStore.shared.dayMeetings(on: day)
    }

    /// Takes a meeting out of the calendar.
    ///
    /// Note what this isn't: a decline. Nothing reachable from a sandboxed
    /// app can answer an invitation — see `CalendarStore.delete` for why —
    /// so the organiser is none the wiser, and the popover says as much
    /// before it does this.
    ///
    /// A full `refreshMeetingData` afterwards rather than dropping the row
    /// locally, because a deleted meeting changes more than the list it was
    /// in: the day's meeting hours, the bar behind them, the week's caption
    /// and the people strip all read from it. Days with hand-dragged
    /// meeting blocks keep theirs, by the same rule that governs every
    /// other refresh.
    func deleteMeeting(_ meeting: DayMeeting, scope: CalendarStore.DeletionScope) async {
        guard let identifier = meeting.eventIdentifier else {
            // A meeting EventKit never gave an identifier to isn't one it
            // can be asked to remove. Rare enough that the honest sentence
            // is better than a disabled button nobody can explain.
            meetingDeleteProblem = "Calendar doesn't recognise that meeting, so it was left alone."
            return
        }

        switch CalendarStore.shared.delete(
            eventIdentifier: identifier,
            startingAt: meeting.start,
            scope: scope
        ) {
        case .deleted, .notFound:
            // Gone either way, so both end with the same refresh: one of
            // them deleted it, the other found somebody already had.
            meetingDeleteProblem = nil
            await refreshMeetingData()
        case .readOnly:
            meetingDeleteProblem = "That calendar is read-only, so the meeting is still there."
        case .failed:
            meetingDeleteProblem = "Calendar wouldn't delete that meeting."
        }
    }

    /// Writes a day's intention and check-in together, since the panel
    /// edits both at once.
    ///
    /// The two timestamps record when each was *first* set, so editing an
    /// old day's wording doesn't restamp it as though it were written
    /// today; clearing the text back to empty drops the timestamp, which is
    /// what returns the day's button to its unfilled state.
    func saveDayEntry(day: Date, goals: String, outcomes: String, reflection: String) {
        let key = dayKey(for: day)
        let existing = intentionsByDay[key]

        // Opening a day and moving on without typing shouldn't leave a
        // record behind. With auto-save, closing the panel always writes,
        // so without this every day merely glanced at would be stored as an
        // empty entry.
        let isBlank = (goals + outcomes + reflection).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard existing != nil || !isBlank else { return }

        var entry = existing ?? DailyIntention(dayKey: key)
        entry.goals = goals
        entry.outcomes = outcomes
        entry.checkInReflection = reflection

        let hasIntentionText = !(goals + outcomes).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        entry.intentionSetAt = hasIntentionText ? (entry.intentionSetAt ?? Date()) : nil
        let hasReflection = !reflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        entry.checkedInAt = hasReflection ? (entry.checkedInAt ?? Date()) : nil

        // Auto-save fires on every close as well as on a debounce, so most
        // calls have nothing new in them; rewriting the file anyway would be
        // churn for no change.
        guard entry != existing else { return }
        intentionsByDay = intentionStore.upsert(entry)
    }

    /// Points the panel at `day`, focused on one of its two sections.
    /// Open a day in the panel without saying which of its two halves is
    /// wanted. The chart asks this way: a column names a day, and with the
    /// sun and moon gone there's nothing in it that names a section — so
    /// whichever the panel was focused on stays focused as you move along
    /// the week.
    func selectDay(_ day: Date) {
        selectDay(day, kind: dayEditor.kind)
    }

    func selectDay(_ day: Date, kind: DailyPromptKind) {
        dayEditor = DayEditorSelection(day: calendar.startOfDay(for: day), kind: kind)
        // Why a meeting on Tuesday couldn't be deleted isn't news about
        // Wednesday, and the panel it was written under is about to show a
        // different day's meetings.
        meetingDeleteProblem = nil
        refreshMeetingGist()
        refreshDerivedMailState()
    }

    /// Asks the on-device model for a phrase describing the panel's day.
    ///
    /// Tracked against the meetings it was generated from rather than
    /// generated once per day: choosing a different calendar, editing an
    /// event, or today simply gaining another meeting all change the list,
    /// and a phrase describing meetings that are no longer shown is worse
    /// than none. Unchanged lists don't ask the model again.
    // MARK: - Mail

    /// Reads the inbox and works through anything new in it.
    ///
    /// Two passes, in order: Mail is asked for the messages, then each one
    /// that hasn't been seen before goes through the model. The second pass
    /// publishes as it goes rather than at the end — a message takes a
    /// second or two, forty of them is a minute, and a column that fills in
    /// row by row is honest about that in a way a spinner isn't.
    func refreshMail() async {
        // A request arriving while one is already running is remembered
        // rather than dropped. Dropping it was fine for the timer, which
        // would come round again in five minutes, and quietly wrong for
        // the one case that matters: choosing a different account in
        // preferences almost always lands on top of the trip to Mail that
        // launch or the timer started, so the column that had just been
        // emptied stayed empty until the next tick.
        guard !isRefreshingMail else {
            mailRefreshQueued = true
            return
        }
        isRefreshingMail = true
        defer { isRefreshingMail = false }

        repeat {
            mailRefreshQueued = false
            // Which account this pass is about to read. Mail is talked to
            // on one serial queue and a fetch takes seconds, so an answer
            // can easily arrive after the account was changed — carrying
            // the *other* mailbox's messages, which is precisely what
            // picking an account is meant to prevent. It's thrown away in
            // that case; the change queued a refresh of its own, so the
            // loop goes round and reads the account that's now selected.
            let account = mailSelection
            let result = await MailStore.shared.fetch()
            guard account == mailSelection else { continue }

            // Asked for on every pass, not only a successful one, and not
            // when preferences opens: the picker is behind a sheet that has
            // to draw immediately, and a trip to Mail takes seconds.
            // Reading the accounts even after a failed fetch is what stops
            // the picker being empty — "No mail accounts available" used to
            // be what you got for opening preferences before the first
            // inbox had arrived, which is precisely when you would go
            // looking for the setting.
            //
            // An empty answer never overwrites a good list. Mail returns
            // nothing here when it is mid-launch or busy, and blanking the
            // list would take the picker off screen under the hand of
            // whoever was using it.
            let accounts = await MailStore.shared.accounts()
            if !accounts.isEmpty { mailAccounts = accounts }

            switch result {
            case .failed(let state):
                mailAccess = state
                // Messages already on screen are left alone. A refusal or a
                // busy Mail is a fact about this attempt, not about the mail —
                // blanking the column on a failed poll would make a working
                // inbox flicker away every time Mail was mid-sync.
            case .fetched(let fetch):
                mailAccess = .granted
                mailScope = fetch.scope
                mailMessages = fetch.messages
                myAddresses = fetch.myAddresses
                await refreshDeferrals()
                await summariseNewMail()
                refreshDerivedMailState()
                await refreshDayBrief()
            }
        } while mailRefreshQueued
    }

    /// Summarises every message without a stored summary, oldest first so
    /// the column fills downward the way it reads.
    private func summariseNewMail() async {
        // Anything never summarised, and anything summarised by a prompt
        // that has since been rewritten.
        let pending = mailMessages.filter {
            mailSummaries[$0.id]?.generatorVersion != MailSummaryGenerator.promptVersion
        }
        guard !pending.isEmpty else { return }

        for message in pending.reversed() {
            let candidates = MailDueDates.candidates(in: message)
            let summary: MailSummary
            if MailSummaryGenerator.isAvailable, #available(macOS 26.0, *) {
                summary = await MailSummaryGenerator.generate(for: message, candidates: candidates)
            } else {
                summary = MailSummaryGenerator.fallback(for: message, candidates: candidates)
            }
            mailSummaries[message.id] = summary
            mailSummaryStore.upsert(summary)
        }
    }

    /// Rewrites the line above the inbox, when what it would be written
    /// from has actually changed.
    private func refreshDayBrief() async {
        let input = dayBriefInput()
        let signature = "\(input)"
        guard lastBriefSignature != signature else { return }
        lastBriefSignature = signature

        guard DayBriefGenerator.isAvailable, #available(macOS 26.0, *) else {
            dayBrief = nil
            return
        }
        let generated = await DayBriefGenerator.generate(for: input)
        // The inbox can change again while the model is thinking, in which
        // case a second pass is already running and this answer describes a
        // day nobody is looking at any more.
        guard lastBriefSignature == signature else { return }
        dayBrief = generated
    }

    /// What the brief is written from: today's meetings, and the action
    /// lines the first pass produced for the messages.
    func dayBriefInput() -> DayBriefGenerator.Input {
        let meetings = meetings(for: Date())
        let soon = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: Date())) ?? Date()
        // Drawn from what's on screen. A brief that counted work you had
        // explicitly put off until Thursday would be describing a day you
        // decided not to have.
        let visible = visibleMailMessages
        let summaries = visible.compactMap { mailSummaries[$0.id] }
        return DayBriefGenerator.Input(
            actionLines: summaries.filter { $0.hasAction }.map(\.action),
            messageCount: visible.count,
            unreadCount: visible.filter(\.isUnread).count,
            dueSoonCount: summaries.filter { ($0.dueDate ?? .distantFuture) < soon }.count,
            meetingTitles: meetings.map(\.title),
            meetingMinutes: meetings.reduce(0) { $0 + $1.durationMinutes }
        )
    }

    /// The summary for a message, once there is one.
    func summary(for message: MailMessage) -> MailSummary? {
        mailSummaries[message.id]
    }

    // MARK: - Deferring

    /// The messages the column shows: everything except what's been put off
    /// until a later day.
    ///
    /// Deferred mail is hidden rather than removed, and `deferredCount`
    /// keeps it one click away — an inbox that silently swallows things is
    /// worse than a full one, because you stop trusting it.
    var visibleMailMessages: [MailMessage] {
        let shown = showsDeferred
            ? mailMessages
            : mailMessages.filter { !MailDeferral.isHidden(mailDeferrals[$0.id]) }

        // Anything due today or already overdue floats to the top, newest
        // first within each group. Received order is the right default for
        // an inbox and the wrong one for a list you're working from: a
        // deadline that lands today matters more than a message that
        // arrived an hour ago, and it was sitting five rows down.
        return shown.sorted { left, right in
            let leftDue = isDueToday(left)
            let rightDue = isDueToday(right)
            if leftDue != rightDue { return leftDue }
            return left.receivedAt > right.receivedAt
        }
    }

    /// Whether this message's deadline has arrived.
    private func isDueToday(_ message: MailMessage) -> Bool {
        guard let due = mailSummaries[message.id]?.dueDate else { return false }
        return calendar.startOfDay(for: due) <= calendar.startOfDay(for: Date())
    }

    var deferredCount: Int {
        mailMessages.filter { MailDeferral.isHidden(mailDeferrals[$0.id]) }.count
    }

    func deferralDate(for message: MailMessage) -> Date? {
        mailDeferrals[message.id]
    }

    /// Puts a message off until `date`.
    ///
    /// Two writes, both to somewhere that already existed: a reminder in
    /// Reminders carrying the date and a link back to the message, and a
    /// flag on the message so Mail shows you which ones you've put off.
    /// Nothing about the deferral is stored by this app.
    func deferMessage(_ message: MailMessage, until date: Date) async {
        guard await RemindersStore.shared.requestAccess() else {
            deferProblem = "Equilibrium needs access to Reminders to defer mail. System Settings › Privacy & Security › Reminders."
            return
        }

        let note = mailSummaries[message.id]?.action
        let written = RemindersStore.shared.addReminder(
            messageID: message.id,
            subject: message.displaySubject,
            note: (note?.isEmpty ?? true) ? nil : note,
            until: date
        )
        guard written else {
            deferProblem = "Couldn't add a reminder — there's no list here to add it to."
            return
        }

        deferProblem = nil
        // Shown straight away rather than waiting for the reminder store to
        // be read back: the row should leave the moment you choose a day.
        mailDeferrals[message.id] = date
        await MailStore.shared.setFlagged(messageID: message.id, flagged: true)
        refreshDerivedMailState()
    }

    /// Brings it back now.
    func undeferMessage(_ message: MailMessage) async {
        await RemindersStore.shared.clear(messageID: message.id)
        await MailStore.shared.setFlagged(messageID: message.id, flagged: false)
        mailDeferrals.removeValue(forKey: message.id)
        deferProblem = nil
        refreshDerivedMailState()
    }

    /// Re-reads the deferrals from Reminders.
    ///
    /// Which makes a reminder completed or deleted in the Reminders app —
    /// or on a phone — bring the message back here, since that store is now
    /// the only record of the decision.
    func refreshDeferrals() async {
        guard RemindersStore.shared.isAuthorized else { return }
        mailDeferrals = await RemindersStore.shared.deferrals()
        refreshDerivedMailState()
    }

    /// Files a message into its account's archive and takes it off screen.
    ///
    /// The row goes on `notFound` as well as on success: either way the
    /// message is no longer in the inbox, and leaving it there would show
    /// something that isn't so.
    func archive(_ message: MailMessage) async {
        switch await MailStore.shared.archive(messageID: message.id) {
        case .archived, .notFound:
            archiveProblem = nil
            mailMessages.removeAll { $0.id == message.id }
            // A deferral on a message that has left the inbox is a decision
            // about something that no longer exists.
            if mailDeferrals[message.id] != nil {
                await RemindersStore.shared.clear(messageID: message.id)
                mailDeferrals.removeValue(forKey: message.id)
            }
            refreshDerivedMailState()
        case .noArchiveMailbox:
            archiveProblem = "That account has no archive mailbox, so the message was left where it is."
        case .failed:
            archiveProblem = "Mail wouldn't archive that message."
        }
    }

    // MARK: - Blocking out time

    /// Where a piece of work from `message` could go, at `minutes` long.
    ///
    /// Read fresh each time rather than cached: this runs when a popover
    /// opens, not on every render, and a slot worked out from a diary five
    /// minutes stale is how you double-book yourself.
    func recommendedBlock(for message: MailMessage, minutes: Int) -> TimeBlockPlanner.Slot? {
        guard calendarAccessGranted else { return nil }
        let days = TimeBlockPlanner.remainingWeekDays()
        return TimeBlockPlanner.firstSlot(
            minutes: minutes,
            busy: CalendarStore.shared.busyIntervals(on: days),
            shifts: preferences.shifts,
            days: days
        )
    }

    /// The days a block can be put on: what's left of this week.
    func blockableDays() -> [Date] {
        TimeBlockPlanner.remainingWeekDays()
    }

    /// The times a block could start on `day`, and whether each is free.
    func blockStartTimes(on day: Date, minutes: Int) -> [(start: Date, isFree: Bool)] {
        let busy = calendarAccessGranted ? CalendarStore.shared.busyIntervals(on: [day]) : []
        return TimeBlockPlanner.startTimes(
            on: day,
            minutes: minutes,
            shifts: preferences.shifts,
            busy: busy
        )
    }

    /// Whether a slot chosen by hand is actually free.
    ///
    /// The recommendation is worked out around the diary, but the moment
    /// someone can move it themselves they can move it onto a meeting —
    /// and a planner that silently double-books is worse than one that
    /// doesn't plan. Cheap enough to call per keystroke: one EventKit read
    /// over the day being looked at.
    func isSlotFree(start: Date, minutes: Int) -> Bool {
        guard calendarAccessGranted else { return true }
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        return !CalendarStore.shared.busyIntervals(on: [start, end]).contains { interval in
            interval.start < end && interval.end > start
        }
    }

    /// Writes the block, and folds it into what's on screen.
    func addFocusBlock(for message: MailMessage, slot: TimeBlockPlanner.Slot) -> Bool {
        let action = mailSummaries[message.id]?.action ?? ""
        let created = CalendarStore.shared.createFocusBlock(
            // Named after the message, since that's what you'll be looking
            // at when the block comes round and you have to remember why
            // you claimed the hour.
            title: message.displaySubject,
            start: slot.start,
            end: slot.end,
            notes: action.isEmpty
                ? "Focus time blocked from a message in Equilibrium."
                : "\(action)\n\nFocus time blocked from a message in Equilibrium."
        )
        guard created else { return false }
        // The chart draws meetings from the calendar, and this event is
        // deliberately not one, so nothing on the bars changes — but the
        // slot is now taken, and the next recommendation has to know.
        Task { await refreshMeetingData() }
        return true
    }

    /// Points the app at one mail account, or back at every account.
    func updateMailSelection(_ identifier: String?) {
        MailStore.shared.updateSelection(identifier)
        mailSelection = identifier
        // The inbox on screen belongs to the account that was just
        // deselected, so it goes immediately rather than lingering until
        // the fetch returns.
        mailMessages = []
        dayBrief = nil
        refreshDerivedMailState()
        Task { await refreshMail() }
    }

    /// Rebuilds the people strip and the counts above the inbox.
    ///
    /// The strip is drawn from the inbox's own window (a week) plus the day
    /// the panel is showing — not the whole visible week of meetings. "At
    /// the moment" is what the strip is for, so paging back to March
    /// shouldn't repopulate it with the people you dealt with then, while
    /// the day you actually selected is the one you're thinking about.
    ///
    /// One EventKit read between them, rather than one per SwiftUI render.
    /// Re-reads the week's meetings and the addresses that are you.
    func reloadWeekMeetings() {
        guard calendarAccessGranted else {
            weekMeetings = []
            calendarSelfAddresses = []
            return
        }
        let days = visibleWeekDays
        weekMeetings = days.flatMap { CalendarStore.shared.dayMeetings(on: $0) }
        calendarSelfAddresses = CalendarStore.shared.currentUserAddresses(on: days)
    }

    func refreshDerivedMailState() {
        // Mail's own accounts, plus any address the calendar recognises as
        // you — see `CalendarStore.currentUserAddresses`. Read from the
        // cache rather than the calendar: this method runs on every day
        // click, and gathering it is a week of EventKit queries.
        let me = myAddresses.union(calendarSelfAddresses)
        // Everyone on the week's events, not just the selected day's, and
        // everyone on a message you haven't put off. The strip answers "who
        // am I working with at the moment": a Tuesday spent looking at
        // Thursday shouldn't empty it of the people you're seeing this week,
        // and a message deferred to next Monday isn't this moment's problem.
        currentPeople = PeopleDirectory.people(
            messages: visibleMailMessages,
            meetings: weekMeetings,
            myAddresses: me,
            myNames: Set(mailAccounts.map(\.fullName).filter { !$0.isEmpty })
        )
        dayBriefFallback = dayBriefInput().fallbackSentence
    }

    func refreshMeetingGist() {
        guard MeetingSummaryGenerator.isAvailable else { return }
        guard #available(macOS 26.0, *) else { return }

        let day = dayEditor.day
        let key = dayKey(for: day)
        let meetings = meetings(for: day)
        guard meetings.count > 1 else {
            // A day whose meetings have gone — a different calendar chosen,
            // an event deleted — shouldn't keep a phrase describing the ones
            // it used to have.
            meetingGists[key] = nil
            lastGistMeetings[key] = nil
            return
        }

        let signature = meetings
            .map { "\($0.id)|\($0.start.timeIntervalSinceReferenceDate)|\($0.end.timeIntervalSinceReferenceDate)|\($0.title)" }
            .joined(separator: "\n")
        guard lastGistMeetings[key] != signature else { return }
        lastGistMeetings[key] = signature

        Task { @MainActor in
            let gist = await MeetingSummaryGenerator.generateGist(for: meetings)
            // The day's meetings can change again while the model is
            // thinking, in which case a second generation is already under
            // way and this answer describes a list nobody is looking at.
            guard lastGistMeetings[key] == signature else { return }
            // Assigned even when nothing comes back, which clears the key:
            // the signature has been recorded, so nothing will ask again for
            // this list, and keeping the old phrase would leave it sitting
            // under meetings it no longer describes.
            meetingGists[key] = gist
        }
    }

    /// Rebuilds the menu bar's line: hours left today, then the next
    /// meeting when there is one.
    func refreshMenuBarText() {
        let left = HoursFormat.string(remainingHoursToday())
        guard let (meeting, standing) = currentOrNextMeeting else {
            menuBarText = left
            menuBarAccessibilityLabel = "\(left) left to work today"
            return
        }

        let title = MeetingTimeFormat.shortTitle(meeting.title)
        switch standing {
        case .now:
            // What matters about a meeting you're already in is when it lets
            // you go, so this shows the end rather than the start — and says
            // "to", so it can't be mistaken for something starting then.
            menuBarText = "\(left) · \(title) to \(MeetingTimeFormat.compactTime(meeting.end))"
            menuBarAccessibilityLabel = "\(left) left to work today. In \(meeting.title) until \(MeetingTimeFormat.compactTime(meeting.end))"
        case .next:
            menuBarText = "\(left) · \(MeetingTimeFormat.compactTime(meeting.start)) \(title)"
            menuBarAccessibilityLabel = "\(left) left to work today. Next: \(meeting.title) at \(MeetingTimeFormat.compactTime(meeting.start))"
        }
    }

    /// Re-reads today's meetings into the cache the menu bar reads from.
    func refreshTodaysMeetings() {
        todaysMeetings = meetings(for: Date()).sorted { $0.start < $1.start }
        refreshMenuBarText()
    }

    /// The phrase for a day's meetings, or nil while there isn't one.
    func meetingGist(for day: Date) -> String? {
        meetingGists[dayKey(for: day)]
    }

    /// Points the panel at today (from the menu bar or a notification tap).
    func presentDailyPrompt(_ kind: DailyPromptKind) {
        selectDay(Date(), kind: kind)
    }

    /// Handles a tap on a daily-intention notification (`userInfo` action).
    func handleNotificationAction(_ action: String?) {
        switch action {
        case "intention":
            presentDailyPrompt(.intention)
        case "checkIn":
            presentDailyPrompt(.checkIn)
        default:
            break
        }
    }
}

