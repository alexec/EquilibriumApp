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
/// Neither is typed: both are dictated, so each field is a transcript with
/// a microphone beside it rather than a text box (see `Dictation`).
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
        initialFocus: DailyPromptKind,
        onSave: @escaping (String, String, String) -> Void
    ) {
        self.day = day
        self.meetings = meetings
        self.existing = existing
        self.allowsCheckIn = allowsCheckIn
        self.calendarAccess = calendarAccess
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
                        dictationField(title: "Goals", prompt: "What do you want to accomplish?", field: .goals, text: $goals)
                            .onChange(of: goals) { _ in scheduleSave() }
                        dictationField(title: "Outcomes", prompt: "What does success look like?", field: .outcomes, text: $outcomes)
                            .onChange(of: outcomes) { _ in scheduleSave() }

                        if allowsCheckIn {
                            Divider()

                            sectionHeader("Check-in", symbol: "moon")
                            dictationField(
                                title: "How did it go?",
                                prompt: "What landed, what didn't, what to carry forward?",
                                field: .reflection,
                                text: $reflection,
                                lines: 3...6
                            )
                            .id(Field.reflection)
                            .onChange(of: reflection) { _ in scheduleSave() }
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
        // Recognition can also stop on its own — a long silence, or an error.
        .onChange(of: dictation.isListening) { listening in
            if !listening { dictatingField = nil }
        }
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

    /// Brings the section whose button was clicked into view — on a day
    /// with a full diary the check-in starts below the fold. There's no
    /// cursor to place any more: the fields take speech, not keystrokes.
    ///
    /// Deferred a runloop turn, since the section it names isn't in the
    /// hierarchy yet while the panel is still being placed.
    private func scrollToSection(proxy: ScrollViewProxy) {
        let field: Field = (initialFocus == .checkIn && allowsCheckIn) ? .reflection : .goals
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(field, anchor: field == .reflection ? .bottom : .top)
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

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Meetings", symbol: "calendar")

            if meetings.isEmpty {
                Text(emptyMeetingsMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if meetings.count > Self.meetingsShownInFull {
                // A heavy day's diary would otherwise push the intention and
                // check-in off the bottom of the panel — the two things this
                // is for. Past this many, the list scrolls within its own
                // fixed height and the fields below stay put.
                ScrollView {
                    meetingRows
                }
                .frame(height: Self.longMeetingListHeight)
            } else {
                meetingRows
            }
        }
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

    private static let meetingsShownInFull = 4
    private static let longMeetingListHeight: CGFloat = 132

    private var meetingRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(meetings) { meeting in
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
            }
        }
    }

    /// A field you speak into. There's no text box: intentions and
    /// check-ins are dictated, so what's here is the transcript, the
    /// microphone that fills it, and a way to wipe it and start again.
    private func dictationField(
        title: String,
        prompt: String,
        field: Field,
        text: Binding<String>,
        lines: ClosedRange<Int> = 2...4
    ) -> some View {
        let isDictating = dictatingField == field

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if !text.wrappedValue.isEmpty && !isDictating {
                    Button("Clear") {
                        text.wrappedValue = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Clear \(title.lowercased())")
                }
                Button {
                    toggleDictation(for: field, text: text)
                } label: {
                    Image(systemName: isDictating ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 12))
                        .foregroundColor(isDictating ? .red : .accentColor)
                }
                .buttonStyle(.plain)
                .help(isDictating ? "Stop dictating" : "Dictate \(title.lowercased())")
                .accessibilityLabel(isDictating ? "Stop dictating \(title.lowercased())" : "Dictate \(title.lowercased())")
            }

            Text(text.wrappedValue.isEmpty ? prompt : text.wrappedValue)
                .font(.system(size: 12))
                .foregroundColor(text.wrappedValue.isEmpty ? .secondary.opacity(0.7) : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: CGFloat(lines.lowerBound) * 15, alignment: .topLeading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(isDictating ? 0.5 : 0), lineWidth: 1)
                )
                .textSelection(.enabled)

            if isDictating {
                Text("Listening…")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            } else if let reason = dictation.unavailableReason, dictatingField == nil {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Starts the microphone on a field, or stops it if that field is
    /// already the one being dictated into. Only one runs at a time.
    private func toggleDictation(for field: Field, text: Binding<String>) {
        guard dictatingField != field else {
            dictation.stop()
            dictatingField = nil
            return
        }
        dictation.stop()
        dictatingField = field
        textBeforeDictation = text.wrappedValue
        Task { await dictation.start() }
    }

    /// "Today" for today, otherwise the weekday and date — enough to be
    /// sure which bar the panel belongs to.
    static func dayTitle(_ day: Date, today: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: today) {
            return "Today"
        }
        let thisYear = calendar.isDate(day, equalTo: today, toGranularity: .year)
        return (thisYear ? dayInYearFormatter : dayWithYearFormatter).string(from: day)
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
