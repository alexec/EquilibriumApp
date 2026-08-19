import SwiftUI

/// Shared time formatter for the panel's meeting rows.
enum MeetingTimeFormat {
    static let range: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static func rangeLabel(start: Date, end: Date) -> String {
        "\(range.string(from: start)) – \(range.string(from: end))"
    }

    /// "2pm", "2:15pm" — no minutes on the hour, which is where most
    /// meetings start. Four characters of menu bar saved on most of them.
    static func compactTime(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let suffix = hour < 12 ? "am" : "pm"
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        return minute == 0
            ? "\(displayHour)\(suffix)"
            : "\(displayHour):\(String(format: "%02d", minute))\(suffix)"
    }

    /// Enough of a title to recognise the meeting by, not enough to push
    /// every other app off the menu bar.
    static func shortTitle(_ title: String, limit: Int = 16) -> String {
        guard title.count > limit else { return title }
        return title.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// One day's meetings, intention and check-in, edited in a panel beside the
/// chart rather than in a modal sheet. Living next to the bars is what
/// makes editing an *old* day sensible: you pick the day in the chart and
/// its detail appears alongside, instead of a dialog that only ever knew
/// about today.
///
/// Both sections are always present — a day's intention and how it actually
/// went belong on screen together, particularly when looking back — so
/// which button was clicked only decides which one is scrolled to.
///
/// Each field can be typed or dictated — whichever fits — with a microphone
/// beside it for when speaking is easier (see `Dictation`).
struct DayDetailPanel: View {
    let day: Date
    let meetings: [DayMeeting]
    let existing: DailyIntention?
    /// Check-ins are hidden for days that haven't happened: there's nothing
    /// to reflect on yet. Intentions stay editable, so tomorrow can be
    /// planned today.
    let allowsCheckIn: Bool
    /// Distinguishes a day with no meetings from one whose meetings can't
    /// be read — without it, an unanswered permission prompt and a refusal
    /// both look exactly like an empty diary.
    let calendarAccess: CalendarAccessState
    /// The on-device model's phrase for this day's meetings, when there is
    /// one. Never load-bearing: the count and hours are computed.
    let meetingGist: String?
    let initialFocus: DailyPromptKind
    let onSave: (String, String, String) -> Void

    @State private var goals: String
    @State private var outcomes: String
    @State private var reflection: String
    /// The pending debounced write; cancelled and replaced as text arrives.
    @State private var saveTask: Task<Void, Never>?

    @StateObject private var dictation = Dictation()
    /// Which field the microphone is currently filling, if any.
    @State private var dictatingField: Field?
    /// What that field held when dictation started — a new run appends to
    /// it rather than replacing what's already there.
    @State private var textBeforeDictation = ""
    /// Long diaries start summarised; the list is one click away.
    @State private var meetingsExpanded = false

    private enum Field: Hashable {
        case goals
        case outcomes
        case reflection
    }

    init(
        day: Date,
        meetings: [DayMeeting],
        existing: DailyIntention?,
        allowsCheckIn: Bool,
        calendarAccess: CalendarAccessState,
        meetingGist: String?,
        initialFocus: DailyPromptKind,
        onSave: @escaping (String, String, String) -> Void
    ) {
        self.day = day
        self.meetings = meetings
        self.existing = existing
        self.allowsCheckIn = allowsCheckIn
        self.calendarAccess = calendarAccess
        self.meetingGist = meetingGist
        self.initialFocus = initialFocus
        self.onSave = onSave
        _goals = State(initialValue: existing?.goals ?? "")
        _outcomes = State(initialValue: existing?.outcomes ?? "")
        _reflection = State(initialValue: existing?.checkInReflection ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        meetingsSection

                        Divider()

                        sectionHeader("Intention", symbol: "sun.max")
                            .id(Field.goals)
                        DictationField(
                            title: "Goals",
                            prompt: "What do you want to accomplish?",
                            text: $goals,
                            isListening: isListening(.goals),
                            onToggle: { toggleDictation(for: .goals, text: $goals) },
                            onBeginEditing: { stopDictation() },
                            onClear: { clearField(.goals, text: $goals) }
                        )
                        .onChange(of: goals) { _ in scheduleSave() }
                        DictationField(
                            title: "Outcomes",
                            prompt: "What does success look like?",
                            text: $outcomes,
                            isListening: isListening(.outcomes),
                            onToggle: { toggleDictation(for: .outcomes, text: $outcomes) },
                            onBeginEditing: { stopDictation() },
                            onClear: { clearField(.outcomes, text: $outcomes) }
                        )
                        .onChange(of: outcomes) { _ in scheduleSave() }

                        if allowsCheckIn {
                            Divider()

                            sectionHeader("Check-in", symbol: "moon")
                            DictationField(
                                title: "How did it go?",
                                prompt: "What landed, what didn't, what to carry forward?",
                                text: $reflection,
                                isListening: isListening(.reflection),
                                onToggle: { toggleDictation(for: .reflection, text: $reflection) },
                                onBeginEditing: { stopDictation() },
                                onClear: { clearField(.reflection, text: $reflection) },
                                minimumLines: 3
                            )
                            .id(Field.reflection)
                            .onChange(of: reflection) { _ in scheduleSave() }
                        }

                        if let reason = dictation.unavailableReason {
                            Text(reason)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onAppear { scrollToSection(proxy: proxy) }
                // The panel is rebuilt per day (see its `.id` at the call
                // site), but clicking the other button on the *same* day only
                // changes the kind, so the focus has to follow that too.
                .onChange(of: initialFocus) { _ in scrollToSection(proxy: proxy) }
            }
        }
        // Whatever is still pending is written before this panel goes away —
        // switching to another day or the window shutting both land here, so
        // nothing dictated is lost by navigating away.
        .onDisappear {
            dictation.stop()
            saveTask?.cancel()
            onSave(goals, outcomes, reflection)
        }
        // Words arrive a few at a time while you speak; each update rewrites
        // the field being dictated into, appended to whatever it held.
        .onChange(of: dictation.transcript) { heard in
            guard let dictatingField, !heard.isEmpty else { return }
            let joined = textBeforeDictation.isEmpty ? heard : textBeforeDictation + " " + heard
            switch dictatingField {
            case .goals: goals = joined
            case .outcomes: outcomes = joined
            case .reflection: reflection = joined
            }
        }
        // Recognition stopping on its own — a long silence, an error — needs
        // no handling: `isListening(_:)` consults the engine, so every
        // microphone returns to its idle state on its own. Clearing
        // `dictatingField` from here is what raced the switch between fields.
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(width: Self.width)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.06))
        )
    }

    static let width: CGFloat = 280

    /// There's no Save button: the panel isn't a dialog you finish with, so
    /// speaking is the whole interaction. Writes are debounced rather than
    /// applied on every recognised phrase, because each one rewrites the
    /// whole intentions file, and the day's button filling in the chart is
    /// the confirmation.
    private static let saveDebounce: Duration = .milliseconds(500)

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            onSave(goals, outcomes, reflection)
        }
    }

    /// Brings the check-in into view when that's what was clicked — on a
    /// day with a full diary it starts below the fold.
    ///
    /// Nothing happens for an intention: it sits near the top already, and
    /// scrolling to it pushed the day's meetings off the top of the panel,
    /// which are the context you write the intention against.
    ///
    /// Deferred a runloop turn, since the section it names isn't in the
    /// hierarchy yet while the panel is still being placed.
    private func scrollToSection(proxy: ScrollViewProxy) {
        guard initialFocus == .checkIn, allowsCheckIn else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(Field.reflection, anchor: .bottom)
            }
        }
    }

    /// No close button: the panel is always on screen, so the only thing
    /// that changes is which day it's showing.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.dayTitle(day))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.top, 16)
    }

    private func sectionHeader(_ title: String, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }

    /// Why there are no meetings listed. "None" is a fact about the day;
    /// the other two are facts about the app, and saying the wrong one
    /// invites someone to go looking for a permission they already
    /// answered — or to assume their diary was empty when it wasn't.
    private var emptyMeetingsMessage: String {
        switch calendarAccess {
        case .granted: return "No meetings on the calendar."
        case .pending: return "Waiting on calendar access."
        case .denied: return "Calendar access is off, so meetings aren't shown."
        }
    }

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Meetings", symbol: "calendar")

            if meetings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(emptyMeetingsMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    // A prompt that never arrives, or one dismissed weeks
                    // ago, looks identical to one still on its way. Saying
                    // where the switch lives costs a line and saves a hunt.
                    if calendarAccess != .granted {
                        Text("System Settings › Privacy & Security › Calendars")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                summary

                if meetingsExpanded || !startsCollapsed {
                    meetingRows
                }
                // Only where folding is possible. Offered whenever the list
                // was expanded, "Show less" outlived the reason for it — a
                // gist clearing, a day losing meetings — and pressing it
                // then did nothing, because the list shows regardless.
                if startsCollapsed {
                    disclosure(
                        meetingsExpanded ? "Show less" : "Show all \(meetings.count)",
                        expanded: !meetingsExpanded
                    )
                }
            }
        }
    }

    /// Whether the list starts folded away.
    ///
    /// `meetingsExpanded` is only ever set by the disclosure, so the two
    /// together already do the right thing when a phrase arrives after the
    /// panel opens: a list standing open merely because nothing described
    /// the day yet folds away, and one the reader opened stays open.
    ///
    /// A phrase describing the day is enough to know what the day was, so
    /// where there's one the titles wait behind "Show all" — they're the
    /// record, wanted when you go looking, not every time you glance. With
    /// no phrase, "5 meetings · 10½h" isn't a description of anything, so
    /// the list stays out unless it's long enough to crowd the page.
    private var startsCollapsed: Bool {
        meetingGist != nil || meetings.count > Self.meetingsShownInFull
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let countAndHours = MeetingSummaryGenerator.countAndHours(meetings) {
                Text(countAndHours)
                    .font(.system(size: 12, weight: .medium))
            }
            if let meetingGist {
                Text(meetingGist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func disclosure(_ title: String, expanded: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                meetingsExpanded = expanded
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    /// Above this many, the day arrives summarised.
    private static let meetingsShownInFull = 4

    /// The day's meetings, each with the camera that joins its call where
    /// the invitation carries one — the same button the menu bar's list
    /// has, in the same place, since this is the list you're looking at
    /// when the window is already open and the menu bar isn't.
    private var meetingRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(meetings) { meeting in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(MeetingTimeFormat.rangeLabel(start: meeting.start, end: meeting.end))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(meeting.title)
                            .font(.system(size: 12))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let joinURL = meeting.joinURL {
                        Button {
                            MeetingLinks.join(joinURL)
                        } label: {
                            Image(systemName: "video.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.accentColor)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Join \(joinURL.host ?? "the call")")
                        // The row already reads out its title and time; the
                        // camera has to name the meeting itself, or it's an
                        // unlabelled button next to six identical ones.
                        .accessibilityLabel("Join \(meeting.title)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func stopDictation() {
        dictation.stop()
        dictatingField = nil
    }

    /// Starts the microphone on a field, or stops it if that field is
    /// already the one being dictated into. Only one runs at a time.
    private func toggleDictation(for field: Field, text: Binding<String>) {
        // Asks the engine, not the intent: dictation stopping on its own —
        // a long silence — leaves the field still claimed, and testing that
        // instead would make the next press merely release it, so speaking
        // again took two.
        guard !isListening(field) else {
            dictation.stop()
            dictatingField = nil
            return
        }
        dictation.stop()
        dictatingField = nil
        let base = text.wrappedValue
        Task { @MainActor in
            await dictation.start()
            // Claimed only once the engine is actually running. Setting it
            // beforehand raced the stop above: that flips `isListening`,
            // and the observer reacting to it could clear the field after
            // this had already pointed at the new one — leaving dictation
            // running with nowhere to put the words. A refused permission
            // lands here too, and simply leaves no field claimed.
            guard dictation.isListening else { return }
            textBeforeDictation = base
            dictatingField = field
        }
    }

    /// True only while this field is the one being dictated into *and* the
    /// engine is actually running, so a microphone never claims to be
    /// listening when it isn't.
    private func isListening(_ field: Field) -> Bool {
        dictatingField == field && dictation.isListening
    }

    /// Wipes a field, stopping dictation into it first: otherwise the next
    /// recognised phrase arrives appended to the text that was there when
    /// dictation began, undoing the clear.
    private func clearField(_ field: Field, text: Binding<String>) {
        if dictatingField == field {
            dictation.stop()
            dictatingField = nil
        }
        textBeforeDictation = ""
        text.wrappedValue = ""
    }

    /// The weekday and date, with "Today" in front of it on the day it is
    /// — enough to be sure which bar the panel belongs to.
    ///
    /// Today keeps its date rather than trading it away for the word: on
    /// its own, "Today" is the one title that never says which column is
    /// meant, and it's the title on screen most of the time.
    static func dayTitle(_ day: Date, today: Date = Date(), calendar: Calendar = .current) -> String {
        let thisYear = calendar.isDate(day, equalTo: today, toGranularity: .year)
        let date = (thisYear ? dayInYearFormatter : dayWithYearFormatter).string(from: day)
        return calendar.isDate(day, inSameDayAs: today) ? "Today · \(date)" : date
    }

    // Built once rather than per render: this is read on every pass over the
    // panel's body, and a DateFormatter is expensive to construct.
    private static let dayInYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMM"
        return formatter
    }()

    private static let dayWithYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM yyyy"
        return formatter
    }()
}
