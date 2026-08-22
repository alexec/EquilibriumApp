import SwiftUI

/// The one question the week gets asked, under the chart it's about.
///
/// Placed here rather than in the day panel because it isn't about a day,
/// and under the chart rather than inside it because the chart's height is
/// worked out to the point (`DailyBarChartView`) and a row that grows as
/// you type would take that space from the bars the answer is about.
///
/// Only shown for a week that has finished — its Friday reached — and for
/// weeks in the past. A week still being lived can't be judged, and asking
/// on Tuesday would train the answer into a formality.
struct WeeklyReviewCard: View {
    let existing: WeeklyReview?
    /// The week's hours, so the question can be asked about a number rather
    /// than in the abstract. Nil for a week with nothing tracked, where
    /// there's no figure to put to it.
    let hours: Double?
    let onSave: (String, WeeklyReview.Verdict?) -> Void

    @State private var answer: String
    @State private var verdict: WeeklyReview.Verdict?
    @State private var isExpanded: Bool
    /// The pending debounced write, cancelled and replaced as words arrive
    /// — the same shape as the day panel's, and for the same reason: this
    /// saves as you speak, with no button to press.
    @State private var saveTask: Task<Void, Never>?

    @StateObject private var dictation = Dictation()
    @State private var isDictating = false
    /// What the field held when dictation started, so a second run appends
    /// rather than replacing.
    @State private var textBeforeDictation = ""

    init(
        existing: WeeklyReview?,
        hours: Double?,
        onSave: @escaping (String, WeeklyReview.Verdict?) -> Void
    ) {
        self.existing = existing
        self.hours = hours
        self.onSave = onSave
        _answer = State(initialValue: existing?.answer ?? "")
        _verdict = State(initialValue: existing?.verdict)
        // An answered week stays folded up: the answer is a line of text,
        // and the editor only opens when there's editing to do.
        _isExpanded = State(initialValue: !(existing?.hasAnswer ?? false))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            question
            verdictRow
            if isExpanded {
                DictationField(
                    title: "In a sentence",
                    prompt: "What made it worth it, or what didn't?",
                    text: $answer,
                    isListening: isDictating && dictation.isListening,
                    onToggle: toggleDictation,
                    onBeginEditing: stopDictation,
                    onClear: clearAnswer,
                    minimumLines: 2
                )
                if let reason = dictation.unavailableReason {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    isExpanded = true
                } label: {
                    Text(answer)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Edit what you wrote about this week")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.06))
        )
        .onChange(of: answer) { _ in scheduleSave() }
        .onChange(of: dictation.transcript) { heard in
            guard isDictating, !heard.isEmpty else { return }
            answer = textBeforeDictation.isEmpty ? heard : textBeforeDictation + " " + heard
        }
        .onDisappear {
            // Paging to another week takes this view with it; the pending
            // write has to land before it goes, or the last sentence spoken
            // is lost to the debounce.
            dictation.stop()
            saveTask?.cancel()
            save()
        }
    }

    /// The question, with the week's own hours in it where there are any.
    /// "Was 43h worth it?" is a different question from "was that worth
    /// it?", and it's the one the app is in a position to ask.
    private var question: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(prompt)
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
    }

    private var prompt: String {
        guard let hours, hours > 0 else { return "Was that week worth it?" }
        return "Was \(HoursFormat.string(hours)) worth it?"
    }

    /// Three buttons, because the point of the coarse answer is that it
    /// costs one click on a Friday afternoon. Pressing the chosen one again
    /// clears it — an answer given by accident has to be retractable, and
    /// there's no other control that would do it.
    private var verdictRow: some View {
        HStack(spacing: 6) {
            ForEach(WeeklyReview.Verdict.allCases) { option in
                Button {
                    verdict = verdict == option ? nil : option
                    isExpanded = true
                    scheduleSave()
                } label: {
                    Text(option.label)
                        .font(.system(size: 11, weight: verdict == option ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.primary.opacity(verdict == option ? 0.14 : 0.06))
                        )
                }
                .buttonStyle(.plain)
                .help(option.meaning)
                .accessibilityLabel(option.meaning)
                .accessibilityAddTraits(verdict == option ? [.isSelected] : [])
            }
            Spacer()
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        onSave(answer, verdict)
    }

    // MARK: - Dictation

    /// The single-field version of `DayDetailPanel`'s logic, and it keeps
    /// that file's hard-won rule: stopping leaves the field claimed, because
    /// the last words spoken are still being transcribed when the
    /// microphone goes quiet and they arrive with nowhere to go otherwise.
    private func toggleDictation() {
        guard !(isDictating && dictation.isListening) else {
            dictation.stop()
            return
        }
        dictation.stop()
        Task { @MainActor in
            await dictation.start()
            guard dictation.isListening else { return }
            textBeforeDictation = answer
            isDictating = true
        }
    }

    private func stopDictation() {
        dictation.stop()
        isDictating = false
    }

    private func clearAnswer() {
        if isDictating {
            dictation.stop()
            isDictating = false
        }
        textBeforeDictation = ""
        answer = ""
    }
}
