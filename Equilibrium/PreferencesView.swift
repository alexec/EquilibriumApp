import SwiftUI

/// Lets the user configure their work schedule by describing it in free
/// text (parsed into structured values by the on-device LLM). No Stepper
/// form — the result is shown back as a plain-English sentence generated
/// from the settings (`WorkPreferences.summarySentence`), which stays
/// hidden until there's something to show: either a prior saved
/// configuration, or a fresh one you've just generated.
///
/// The text box starts pre-filled with an example sentence rather than a
/// non-interactive placeholder — it's real, editable content from the
/// start, so there's something concrete to tweak instead of a blank box.
struct PreferencesView: View {
    let current: WorkPreferences
    let onSave: (WorkPreferences) -> Void
    /// Calendars offered by the picker; empty when access hasn't been granted.
    let calendars: [SelectableCalendar]
    /// Current calendar selection, `nil` when every calendar is read.
    let calendarSelection: Set<String>?
    let onCalendarSelectionChange: (Set<String>?) -> Void

    @State private var freeText: String
    @State private var draft: WorkPreferences
    @State private var hasResult: Bool
    @State private var isGenerating = false
    @State private var generationFailed = false

    private static let examplePrompt = "I'd like to work a balanced 9-5 week with 3h of meetings a day, and 5h of focus time."

    init(
        current: WorkPreferences,
        calendars: [SelectableCalendar],
        calendarSelection: Set<String>?,
        onCalendarSelectionChange: @escaping (Set<String>?) -> Void,
        onSave: @escaping (WorkPreferences) -> Void
    ) {
        self.current = current
        self.onSave = onSave
        self.calendars = calendars
        self.calendarSelection = calendarSelection
        self.onCalendarSelectionChange = onCalendarSelectionChange
        _draft = State(initialValue: current)
        _freeText = State(initialValue: Self.examplePrompt)
        // Only show a result up front if there's already a real, previously
        // configured (or generated) preference — not just the defaults.
        _hasResult = State(initialValue: current != .default)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Work Preferences")
                .font(.headline)

            if WorkPreferencesGenerator.isAvailable {
                describeYourWeekSection
            } else {
                Text("On-device AI isn't available on this Mac, so preferences can't be configured here yet.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Divider()

            CalendarPickerView(
                calendars: calendars,
                selection: calendarSelection,
                onChange: onCalendarSelectionChange
            )

            if hasResult {
                Divider()
                Text(draft.summarySentence)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button("Save") {
                        onSave(draft)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var describeYourWeekSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Describe your ideal week")
                .font(.system(size: 12, weight: .medium))

            // A single-line field rather than TextEditor: this is meant to
            // be one short sentence, and only TextField supports Enter
            // submitting (via onSubmit) — TextEditor treats Return as a
            // newline, with no way to hook Enter into generating instead.
            TextField("", text: $freeText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
                .onSubmit {
                    generate()
                }

            HStack {
                if generationFailed {
                    Text("Couldn't understand that — try rephrasing.")
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
                hasResult = true
            } else {
                generationFailed = true
            }
        }
    }
}
