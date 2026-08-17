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
/// which button was clicked only decides where the cursor starts.
struct DayDetailPanel: View {
    let day: Date
    let meetings: [DayMeeting]
    let existing: DailyIntention?
    /// Check-ins are hidden for days that haven't happened: there's nothing
    /// to reflect on yet. Intentions stay editable, so tomorrow can be
    /// planned today.
    let allowsCheckIn: Bool
    /// Distinguishes a day with no meetings from one whose meetings simply
    /// can't be read yet — without it, an unanswered permission prompt
    /// looks exactly like an empty diary.
    let calendarAccessGranted: Bool
    let initialFocus: DailyPromptKind
    let onSave: (String, String, String) -> Void

    @State private var goals: String
    @State private var outcomes: String
    @State private var reflection: String
    @FocusState private var focusedField: Field?
    /// The pending debounced write; cancelled and replaced on each keystroke.
    @State private var saveTask: Task<Void, Never>?

    private enum Field {
        case goals
        case reflection
    }

    init(
        day: Date,
        meetings: [DayMeeting],
        existing: DailyIntention?,
        allowsCheckIn: Bool,
        calendarAccessGranted: Bool,
        initialFocus: DailyPromptKind,
        onSave: @escaping (String, String, String) -> Void
    ) {
        self.day = day
        self.meetings = meetings
        self.existing = existing
        self.allowsCheckIn = allowsCheckIn
        self.calendarAccessGranted = calendarAccessGranted
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
                        field(title: "Goals", prompt: "What do you want to accomplish?", text: $goals)
                            .focused($focusedField, equals: .goals)
                            .onChange(of: goals) { _ in scheduleSave() }
                        field(title: "Outcomes", prompt: "What does success look like?", text: $outcomes)
                            .onChange(of: outcomes) { _ in scheduleSave() }

                        if allowsCheckIn {
                            Divider()

                            sectionHeader("Check-in", symbol: "moon")
                            field(
                                title: "How did it go?",
                                prompt: "What landed, what didn't, what to carry forward?",
                                text: $reflection,
                                lines: 3...6
                            )
                            .focused($focusedField, equals: .reflection)
                            .id(Field.reflection)
                            .onChange(of: reflection) { _ in scheduleSave() }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onAppear { applyInitialFocus(proxy: proxy) }
                // The panel is rebuilt per day (see its `.id` at the call
                // site), but clicking the other button on the *same* day only
                // changes the kind, so the focus has to follow that too.
                .onChange(of: initialFocus) { _ in applyInitialFocus(proxy: proxy) }
            }
        }
        // Whatever is still pending is written before this panel goes away —
        // closing it, switching to another day, or the window shutting all
        // land here, so nothing typed is lost by navigating away.
        .onDisappear {
            saveTask?.cancel()
            onSave(goals, outcomes, reflection)
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
    /// typing is the whole interaction. Writes are debounced rather than
    /// per-keystroke because each one rewrites the whole intentions file,
    /// and the day's button filling in the chart is the confirmation.
    private static let saveDebounce: Duration = .milliseconds(500)

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            onSave(goals, outcomes, reflection)
        }
    }

    /// Puts the cursor in the section whose button was clicked and scrolls
    /// it into view — on a day with a full diary the check-in starts below
    /// the fold, and focus alone would leave you typing into a field you
    /// can't see.
    ///
    /// Deferred a runloop turn: setting `@FocusState` while the panel is
    /// still being placed doesn't take — the field it names isn't in the
    /// hierarchy yet, and the focus is dropped.
    private func applyInitialFocus(proxy: ScrollViewProxy) {
        let field: Field = (initialFocus == .checkIn && allowsCheckIn) ? .reflection : .goals
        DispatchQueue.main.async {
            focusedField = field
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
                Text(calendarAccessGranted ? "No meetings on the calendar." : "Waiting on calendar access.")
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

    private func field(
        title: String,
        prompt: String,
        text: Binding<String>,
        lines: ClosedRange<Int> = 2...4
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(lines)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }

    /// "Today" for today, otherwise the weekday and date — enough to be
    /// sure which bar the panel belongs to.
    static func dayTitle(_ day: Date, today: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: today) {
            return "Today"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(day, equalTo: today, toGranularity: .year) ? "EEEE d MMM" : "EEE d MMM yyyy"
        return formatter.string(from: day)
    }
}
