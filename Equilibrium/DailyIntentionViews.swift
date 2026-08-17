import SwiftUI

/// Shared time formatter for meeting rows in intention / check-in sheets.
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

/// First step of the morning flow: today's meetings, then goals and outcomes.
struct IntentionView: View {
    let meetings: [DayMeeting]
    let existing: DailyIntention?
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var goals: String
    @State private var outcomes: String

    init(
        meetings: [DayMeeting],
        existing: DailyIntention?,
        onSave: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.meetings = meetings
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
        _goals = State(initialValue: existing?.goals ?? "")
        _outcomes = State(initialValue: existing?.outcomes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Today's intention")
                .font(.headline)

            meetingsSection

            Divider()

            field(title: "Goals", prompt: "What do you want to accomplish?", text: $goals)
            field(title: "Outcomes", prompt: "What does success look like by end of day?", text: $outcomes)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save intention") {
                    onSave(goals, outcomes)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var canSave: Bool {
        !goals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !outcomes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meetings today")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if meetings.isEmpty {
                Text("No meetings on the calendar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(meetings) { meeting in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(MeetingTimeFormat.rangeLabel(start: meeting.start, end: meeting.end))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            Text(meeting.title)
                                .font(.system(size: 12))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func field(title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            TextField(prompt, text: text, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }
}

/// End-of-day check-in: meetings, morning intention, then a short reflection.
struct CheckInView: View {
    let meetings: [DayMeeting]
    let intention: DailyIntention?
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var reflection: String

    init(
        meetings: [DayMeeting],
        intention: DailyIntention?,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.meetings = meetings
        self.intention = intention
        self.onSave = onSave
        self.onCancel = onCancel
        _reflection = State(initialValue: intention?.checkInReflection ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("End-of-day check-in")
                .font(.headline)

            meetingsSection

            Divider()

            intentionSection

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("How did it go?")
                    .font(.system(size: 12, weight: .medium))
                TextField("What landed, what didn't, what to carry forward?", text: $reflection, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                    )
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save check-in") {
                    onSave(reflection)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meetings today")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if meetings.isEmpty {
                Text("No meetings on the calendar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(meetings) { meeting in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(MeetingTimeFormat.rangeLabel(start: meeting.start, end: meeting.end))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            Text(meeting.title)
                                .font(.system(size: 12))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var intentionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This morning's intention")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if let intention, intention.hasIntention {
                if !intention.goals.isEmpty {
                    labeledBlock(title: "Goals", body: intention.goals)
                }
                if !intention.outcomes.isEmpty {
                    labeledBlock(title: "Outcomes", body: intention.outcomes)
                }
            } else {
                Text("No intention was set today.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func labeledBlock(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
            Text(body)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
