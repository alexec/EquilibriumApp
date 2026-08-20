import SwiftUI

/// Lets the user configure their work schedule by describing it in free
/// text (parsed into structured values by the on-device LLM). The result is
/// shown back as a plain-English sentence generated from the settings
/// (`WorkPreferences.summarySentence`), which stays hidden until there's
/// something to show: either a prior saved configuration, or a fresh one
/// you've just generated.
///
/// The text box starts pre-filled with an example sentence rather than a
/// non-interactive placeholder — it's real, editable content from the
/// start, so there's something concrete to tweak instead of a blank box.
///
/// On Macs where the on-device model isn't available — most of them, for
/// now: anything before macOS 26, every Intel Mac, and any Mac with Apple
/// Intelligence switched off — the text box is replaced by
/// `WorkPreferencesForm`'s controls, which reach exactly the same settings.
/// This panel is the only way to set a work schedule at all, so it can't be
/// allowed to depend on an LLM that most machines don't have.
struct PreferencesView: View {
    let current: WorkPreferences
    let onSave: (WorkPreferences) -> Void
    /// Calendars offered by the picker; empty when access hasn't been granted.
    let calendars: [SelectableCalendar]
    /// Chosen calendar, `nil` when every calendar is read.
    let calendarSelection: String?
    let onCalendarSelectionChange: (String?) -> Void
    /// Mail accounts offered by the picker; empty when Mail hasn't been
    /// read yet, or automation was declined.
    let mailAccounts: [SelectableMailAccount]
    let mailSelection: String?
    let onMailSelectionChange: (String?) -> Void

    @State private var freeText: String
    @State private var draft: WorkPreferences
    @State private var hasResult: Bool
    @State private var isGenerating = false
    @State private var generationFailed = false

    /// Why the free-text path is off, or nil when the model is usable.
    /// Captured once at init rather than re-read on every `body` evaluation:
    /// it can't meaningfully change while this small popover is open, and
    /// re-querying the framework mid-layout would be needless work.
    private let modelUnavailability: OnDeviceModel.Unavailability?

    private static let examplePrompt = "I'd like to work 9 to 5 with an hour for lunch, 3h of meetings a day, and 5h of focus time."

    init(
        current: WorkPreferences,
        calendars: [SelectableCalendar],
        calendarSelection: String?,
        onCalendarSelectionChange: @escaping (String?) -> Void,
        mailAccounts: [SelectableMailAccount],
        mailSelection: String?,
        onMailSelectionChange: @escaping (String?) -> Void,
        onSave: @escaping (WorkPreferences) -> Void
    ) {
        self.current = current
        self.onSave = onSave
        self.calendars = calendars
        self.calendarSelection = calendarSelection
        self.onCalendarSelectionChange = onCalendarSelectionChange
        self.mailAccounts = mailAccounts
        self.mailSelection = mailSelection
        self.onMailSelectionChange = onMailSelectionChange
        self.modelUnavailability = OnDeviceModel.unavailability
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

            if let modelUnavailability {
                manualSection(explanation: modelUnavailability.message)
            } else {
                describeYourWeekSection
            }

            Divider()

            CalendarPickerView(
                calendars: calendars,
                selection: calendarSelection,
                onChange: onCalendarSelectionChange
            )

            MailAccountPickerView(
                accounts: mailAccounts,
                selection: mailSelection,
                onChange: onMailSelectionChange
            )

            // The generated sentence is the only feedback the free-text path
            // gives, so it appears as soon as there's a result. The manual
            // controls already show their own values, so they skip it and go
            // straight to Save — which is always available there, since the
            // draft is editable from the moment the panel opens.
            if hasResult || modelUnavailability != nil {
                Divider()
                if modelUnavailability == nil {
                    Text(draft.summarySentence)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
        // Wide enough for a shift row: a checkbox, its slot's name, and two
        // hour pickers with a word between them.
        .frame(width: 340)
    }

    private func manualSection(explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your ideal week")
                .font(.system(size: 12, weight: .medium))

            WorkPreferencesForm(preferences: $draft)

            Text(explanation)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
