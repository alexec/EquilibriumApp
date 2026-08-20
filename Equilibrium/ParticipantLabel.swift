import SwiftUI

/// "Alex Collins +3" — who a thing came from, and how many other people are
/// on it.
///
/// One view for both messages and meetings deliberately. An email's sender
/// with four people copied and a meeting's organiser with four attendees
/// are the same fact about your day, and showing them the same way is what
/// lets the eye run down the two lists as one. The names behind the `+n`
/// are in the tooltip rather than on screen: the count is what you scan,
/// the names are what you check.
struct ParticipantLabel: View {
    let primary: Person
    let others: [Person]
    /// Meetings sit in a narrower column than messages do.
    var limit: Int = 22

    var body: some View {
        HStack(spacing: 4) {
            Text(MeetingTimeFormat.shortTitle(primary.displayName, limit: limit))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if !others.isEmpty {
                Text("+\(others.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.12))
                    )
            }
        }
        .help(tooltip)
        // One label, not a name and a number read out as separate elements.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Everyone, in full, for the pointer. This is the only place the other
    /// names appear, so it lists them rather than trimming to a few.
    private var tooltip: String {
        guard !others.isEmpty else { return primary.displayName }
        return ([primary] + others).map(\.displayName).joined(separator: "\n")
    }

    private var accessibilityLabel: String {
        guard !others.isEmpty else { return primary.displayName }
        let noun = others.count == 1 ? "other person" : "other people"
        return "\(primary.displayName) and \(others.count) \(noun)"
    }
}
