import SwiftUI

/// One thing you say out loud: a titled field filled by dictation rather
/// than typing.
///
/// It has two shapes. While there's nothing to show, the microphone is the
/// field — centred, with the question underneath, so it reads as "press
/// this and answer that". Once there are words, they become the content and
/// the microphone retreats to the top right, where it's available for
/// adding more without competing with what's already been said.
///
/// The component owns none of the speech machinery. Only one field can be
/// listening at a time, which is a decision for whoever is showing them, so
/// listening state arrives as a flag and presses leave as a callback (see
/// `DayDetailPanel`).
struct DictationField: View {
    let title: String
    /// What the person is being asked to say — shown under the microphone
    /// while the field is empty, which is when they need to know it.
    let prompt: String
    @Binding var text: String
    let isListening: Bool
    let onToggle: () -> Void

    /// Height of the text area once there's something in it, in lines, so
    /// the panel doesn't jump as words arrive.
    var minimumLines: Int = 2

    /// The centred prompt only makes sense while the field has nothing to
    /// show; from the first word on, the words are the point.
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
                    Button("Clear") { text = "" }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Clear \(title.lowercased())")
                    microphone(size: 12)
                }
            }

            if isEmpty {
                emptyState
            } else {
                Text(text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: CGFloat(minimumLines) * 15, alignment: .topLeading)
                    .padding(8)
                    .background(fieldBackground)
                    .textSelection(.enabled)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            microphone(size: 20)
            Text(isListening ? "Listening…" : prompt)
                .font(.system(size: 11))
                .foregroundColor(isListening ? .red : .secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(fieldBackground)
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
