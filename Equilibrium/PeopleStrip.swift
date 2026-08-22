import SwiftUI

/// The people your day is made of, along the bottom of the window.
///
/// Events and messages are both, underneath, someone asking you for
/// something — and until now the app showed the asking and hid the asker.
/// The strip puts them back: who wrote, who called the meeting, and who
/// else was in the room.
///
/// Two weights, not two lists. The people who asked something of you are
/// drawn solid; everyone who was merely also there sits in the same flow,
/// lighter and smaller. Splitting them into separate labelled lists was the
/// alternative, and it made a filing system out of what should be a glance.
///
/// Solid and light are interleaved rather than blocked, because the order
/// is the totals on the chips — most of your week first, whoever they are.
/// See `PeopleDirectory`.
///
/// The chips wrap and the strip scrolls downward, rather than running off
/// the right-hand edge: a horizontal row put everyone past the fourth
/// person behind a scroll gesture nobody performs, which for a panel whose
/// whole job is "who is in your week" meant most of the answer was hidden.
struct PeopleStrip: View {
    static let height: CGFloat = 110

    /// How many people the strip will draw before it stops counting.
    ///
    /// A busy week runs to hundreds of addresses — every cc line on every
    /// message, every room full of attendees — and drawing all of them
    /// turns a glance into a directory: the people who actually asked
    /// something of you end up at the top of a scroll view several screens
    /// long, which is the same failure as the horizontal row, just
    /// rotated. Twenty is roughly what fits in three or four wrapped lines,
    /// so the ordering `PeopleDirectory` establishes stays visible in one
    /// or two flicks.
    ///
    /// The cap lives here rather than in `PeopleDirectory` because it's a
    /// fact about how much room this panel has, not about who is in your
    /// week; the rule stays whole and anything else that reads it gets
    /// everybody.
    static let maximumPeople = 20

    let people: [PersonActivity]
    /// Who the week is being read through, if anyone.
    let focused: Person?
    /// Presses a chip. Pressing the focused one again clears the focus.
    let onSelect: (Person) -> Void

    /// Whoever the cap left out. Counted rather than silently dropped: a
    /// list that stops without saying so reads as the complete answer, and
    /// "who am I working with" is exactly the question where a wrong
    /// complete answer matters.
    private var hiddenCount: Int { max(0, people.count - Self.maximumPeople) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "person.2")
                    .font(.system(size: 10))
                Text("People")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                // The way out, next to the title rather than on the chip:
                // a filtered window has to say so somewhere that doesn't
                // move when the chips reflow, and the chip itself is busy
                // being the thing you pressed.
                if let focused {
                    Button {
                        onSelect(focused)
                    } label: {
                        HStack(spacing: 3) {
                            Text("Showing \(focused.displayName) only")
                            Image(systemName: "xmark.circle.fill")
                        }
                        .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Show the whole week again")
                }
            }
            .foregroundStyle(.secondary)

            if people.isEmpty {
                Text("Nobody in this week's mail or meetings yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    FlowLayout(spacing: 8, lineSpacing: 6) {
                        ForEach(people.prefix(Self.maximumPeople)) { activity in
                            PersonChip(
                                activity: activity,
                                isFocused: focused?.address == activity.person.address,
                                onSelect: { onSelect(activity.person) }
                            )
                        }
                        if hiddenCount > 0 {
                            MorePeopleChip(count: hiddenCount)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
                }
            }
        }
        .frame(height: Self.height, alignment: .topLeading)
    }
}

/// The tail of the list, as one chip. Deliberately not a chip you can
/// press to expand: the people past the twentieth are the ones who were
/// copied in once, and a control that fills the strip with them is a
/// control for undoing the truncation.
private struct MorePeopleChip: View {
    let count: Int

    var body: some View {
        Text("+\(count) more")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(height: 30)
            .background(Capsule().fill(Color.secondary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1))
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }

    private var label: String {
        "\(count) more \(count == 1 ? "person was" : "people were") on this week's messages or in its meetings"
    }
}

private struct PersonChip: View {
    let activity: PersonActivity
    /// Whether the window is currently being read through this person.
    let isFocused: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) { chip }
            .buttonStyle(.plain)
            .help(tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tooltip)
            .accessibilityHint(isFocused ? "Show the whole week again" : "Show only this person's week")
            .accessibilityAddTraits(isFocused ? [.isSelected] : [])
    }

    private var chip: some View {
        HStack(spacing: 6) {
            initialsCircle
            VStack(alignment: .leading, spacing: 1) {
                // Trimmed rather than left to wrap or squeeze: names here
                // run to "Sadaf Kazmi (Funding Circle)", and three of those
                // fill the row on their own, pushing the people who were
                // merely copied in off the end where nobody scrolls.
                Text(MeetingTimeFormat.shortTitle(activity.person.displayName, limit: 18))
                    .font(.system(size: 11, weight: activity.isPrimary ? .medium : .regular))
                    .lineLimit(1)
                // Shown on every chip, primary or not. The count is what
                // the order is built from — someone who sent two and was
                // copied on two outranks someone who sent one — and an
                // order whose reason isn't on screen reads as no order at
                // all. It was hidden on secondary chips at first, on the
                // grounds that being copied in is someone else's
                // conversation; but then the second line of the strip
                // appeared to be in no particular sequence.
                Text(activity.reason)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(activity.isPrimary ? 0.12 : 0.05))
        )
        .overlay(
            // The focused chip is outlined in the accent colour rather than
            // filled with it: a chip is already drawn two ways to say
            // primary or secondary, and a third fill would be a third
            // meaning in the same place.
            Capsule()
                .strokeBorder(
                    isFocused ? Color.accentColor : Color.secondary.opacity(activity.isPrimary ? 0 : 0.15),
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
        .contentShape(Capsule())
    }

    private var initialsCircle: some View {
        Text(activity.person.initials)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(activity.isPrimary ? Color.white : Color.secondary)
            .frame(width: 20, height: 20)
            .background(
                Circle().fill(
                    activity.isPrimary
                        ? Color.accentColor
                        : Color.secondary.opacity(0.15)
                )
            )
    }

    /// The address matters here in a way it doesn't on screen: two people
    /// with the same name are told apart by it, and it's how you'd search
    /// for them in Mail.
    private var tooltip: String {
        let role = activity.isPrimary ? "Asked something of you" : "Also on your messages or in your meetings"
        let counts = activity.reason.isEmpty ? "" : "\n\(activity.reason)"
        return "\(activity.person.displayName)\n\(activity.person.address)\n\(role)\(counts)"
    }
}
