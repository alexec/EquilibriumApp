import SwiftUI

/// One intention or check-in field: type or dictate, whichever suits the
/// moment.
///
/// A multiline editor is always available; the microphone beside the title
/// fills it by voice. While empty, the prompt sits in the field as a
/// placeholder — centred-feeling copy that disappears once there are words.
///
/// The component owns none of the speech machinery. Only one field can be
/// listening at a time, which is a decision for whoever is showing them, so
/// listening state arrives as a flag and presses leave as a callback (see
/// `DayDetailPanel`).
struct DictationField: View {
    let title: String
    /// What the person is being asked to say — shown as a placeholder while
    /// the field is empty.
    let prompt: String
    @Binding var text: String
    let isListening: Bool
    let onToggle: () -> Void
    /// Called when the person clicks into the editor so dictation can stop
    /// before typed edits race with the transcript stream.
    let onBeginEditing: () -> Void
    /// Clearing has to go through the panel rather than just emptying the
    /// binding: if this field is mid-dictation, the next recognised phrase
    /// would be appended to the text that was there when it started and put
    /// it all straight back.
    let onClear: () -> Void

    /// Height of the text area, in lines, so the panel doesn't jump as words
    /// arrive.
    var minimumLines: Int = 2

    @FocusState private var isFocused: Bool

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if !isEmpty {
                    Button("Clear", action: onClear)
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Clear \(title.lowercased())")
                }
                microphone(size: 12)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 12))
                    .focused($isFocused)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, minHeight: CGFloat(minimumLines) * 15, alignment: .topLeading)
                    .padding(4)
                    .background(fieldBackground)
                    .onChange(of: isFocused) { focused in
                        if focused { onBeginEditing() }
                    }

                if isEmpty {
                    Text(isListening ? "Listening…" : prompt)
                        .font(.system(size: 11))
                        .foregroundColor(isListening ? .red : .secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func microphone(size: CGFloat) -> some View {
        Button(action: onToggle) {
            Image(systemName: isListening ? "stop.circle.fill" : "mic.fill")
                .font(.system(size: size))
                .foregroundColor(isListening ? .red : .accentColor)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isListening ? "Stop dictating" : "Dictate \(title.lowercased())")
        .accessibilityLabel(isListening ? "Stop dictating \(title.lowercased())" : "Dictate \(title.lowercased())")
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.red.opacity(isListening ? 0.5 : 0), lineWidth: 1)
            )
    }
}
