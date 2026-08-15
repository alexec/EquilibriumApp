import SwiftUI

/// Lets the user configure their work schedule either by typing a free-text
/// description (parsed into structured values by the on-device LLM) or by
/// adjusting the fields directly — the latter always works, even when
/// Foundation Models is unavailable, since it's the only way to set
/// preferences on a Mac without Apple Intelligence.
struct PreferencesView: View {
    let current: WorkPreferences
    let onSave: (WorkPreferences) -> Void

    @State private var freeText: String = ""
    @State private var draft: WorkPreferences
    @State private var isGenerating = false
    @State private var generationFailed = false

    private static let examplePrompt = "I'd like to work a balanced 9-5 week with 3h of meetings a day, and 5h of focus time."

    init(current: WorkPreferences, onSave: @escaping (WorkPreferences) -> Void) {
        self.current = current
        self.onSave = onSave
        _draft = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Work Preferences")
                .font(.headline)

            if WorkPreferencesGenerator.isAvailable {
                describeYourWeekSection
            } else {
                Text("On-device AI isn't available on this Mac, so set these directly below.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Divider()

            manualFieldsSection

            HStack {
                Spacer()
                Button("Save") {
                    onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var describeYourWeekSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Describe your ideal week")
                .font(.system(size: 12, weight: .medium))

            ZStack(alignment: .topLeading) {
                TextEditor(text: $freeText)
                    .font(.system(size: 12))
                    .frame(height: 60)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                    )
                if freeText.isEmpty {
                    Text(Self.examplePrompt)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }

            HStack {
                if generationFailed {
                    Text("Couldn't understand that — try rephrasing, or set the fields below directly.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    generate()
                } label: {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Generate")
                    }
                }
                .disabled(isGenerating || freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var manualFieldsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(
                "Weekly target: \(HoursFormat.string(draft.weeklyTargetHours))",
                value: $draft.weeklyTargetHours,
                in: 5...80,
                step: 1
            )
            Stepper(
                "Workday start: \(hourLabel(draft.workdayStartHour))",
                value: $draft.workdayStartHour,
                in: 0...(draft.workdayEndHour - 1),
                step: 1
            )
            Stepper(
                "Workday end: \(hourLabel(draft.workdayEndHour))",
                value: $draft.workdayEndHour,
                in: (draft.workdayStartHour + 1)...24,
                step: 1
            )

            optionalHoursStepper(
                label: "Meetings/day target",
                value: $draft.targetMeetingHoursPerDay
            )
            optionalHoursStepper(
                label: "Focus/day target",
                value: $draft.targetFocusHoursPerDay
            )
        }
        .font(.system(size: 12))
    }

    /// A Stepper for an optional hours/day value, with a toggle to
    /// enable/disable it entirely (nil = "no target set").
    private func optionalHoursStepper(label: String, value: Binding<Double?>) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { value.wrappedValue != nil },
                set: { enabled in value.wrappedValue = enabled ? (value.wrappedValue ?? 2) : nil }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            if let bound = value.wrappedValue {
                Stepper(
                    "\(label): \(HoursFormat.string(bound))",
                    value: Binding(get: { bound }, set: { value.wrappedValue = $0 }),
                    in: 0...16,
                    step: 0.5
                )
            } else {
                Text("\(label): not set")
                    .foregroundColor(.secondary)
            }
        }
    }

    private func hourLabel(_ hour: Double) -> String {
        let period = hour < 12 || hour == 24 ? "am" : "pm"
        let displayHour = hour == 0 || hour == 24 ? 12 : (hour > 12 ? hour - 12 : hour)
        return "\(Int(displayHour))\(period)"
    }

    private func generate() {
        guard #available(macOS 26.0, *) else { return }
        isGenerating = true
        generationFailed = false
        let text = freeText
        Task {
            let parsed = await WorkPreferencesGenerator.parse(text)
            isGenerating = false
            if let parsed {
                draft = parsed
            } else {
                generationFailed = true
            }
        }
    }
}
