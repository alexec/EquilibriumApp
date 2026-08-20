import SwiftUI

/// What you can do about one meeting.
///
/// The same panel the inbox rows got, for the same reason. A meeting row
/// used to carry a small camera button, which meant the useful action was
/// an eleven-point target sitting next to five identical ones, and the rest
/// of the row — much the easier thing to hit — did nothing at all. Here the
/// row is the target, and what it opens says who's coming and offers the
/// two things you ever want: get into the call, or go and look at the
/// invitation.
///
/// Joining comes first because it's the one with a clock on it. Opening
/// Calendar is what you do when the row hasn't told you enough, which the
/// attendee list below usually has.
struct MeetingActionPopover: View {
    let meeting: DayMeeting
    let day: Date
    let onJoin: (URL) -> Void
    let onOpenInCalendar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading

            VStack(spacing: 4) {
                if let joinURL = meeting.joinURL {
                    action("Join the call", symbol: "video.fill") { onJoin(joinURL) }
                }
                action("Open in Calendar", symbol: "calendar", onOpenInCalendar)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(MeetingTimeFormat.rangeLabel(start: meeting.start, end: meeting.end))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)

            Text(meeting.title)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            // Named rather than counted. The row outside says "Sarah +4",
            // which is what you scan; this is where you find out who the
            // four are, and it's the usual reason for opening the
            // invitation at all.
            //
            // Named up to a point, that is: an all-hands with sixty people
            // on it turned this line into a wall of text taller than the
            // popover, which pushed the two buttons off the bottom and told
            // you nothing you could read. So the first few names are
            // spelled out and the rest become a count, which is the same
            // trade the row outside makes — the difference being that here
            // you get several names instead of one.
            if !everyone.isEmpty {
                Text(nameList)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    // The full list stays reachable, the same way it is on
                    // the row: on the pointer, one name per line.
                    .help(everyone.map(\.displayName).joined(separator: "\n"))
            }

            if meeting.joinURL == nil, !meeting.participants.isEmpty {
                Text("No call link on the invitation.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// How many names are spelled out before the rest are counted. Six
    /// fills about four lines at this width, which is as much of the
    /// popover as the list can have without crowding the buttons under it.
    private static let namesShown = 6

    /// "Sarah, Tom, Jo, Ann, Ben, Kim… and 54 others".
    ///
    /// A remainder of one is written out instead of counted — "… and 1
    /// other" costs more characters than the name it's hiding.
    private var nameList: String {
        let names = everyone.map(\.displayName)
        guard names.count > Self.namesShown + 1 else {
            return names.joined(separator: ", ")
        }
        let shown = names.prefix(Self.namesShown).joined(separator: ", ")
        return "\(shown)… and \(names.count - Self.namesShown) others"
    }

    /// Organiser first, then everyone else — the order the invitation was
    /// written in, which is the order you'd read it out.
    private var everyone: [Person] {
        guard let organizer = meeting.organizer else { return meeting.participants }
        return [organizer] + meeting.participants.filter { $0 != organizer }
    }

    private func action(
        _ title: String,
        symbol: String,
        _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(MeetingActionButtonStyle())
    }
}

/// Fills in behind a row on hover, so a full-width target looks like one.
private struct MeetingActionButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (isHovering ? 0.07 : 0)))
            )
            .onHover { isHovering = $0 }
    }
}
