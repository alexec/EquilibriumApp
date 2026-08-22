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
/// attendee list below usually has, and deleting is last because it's the
/// only one that can't be taken back.
///
/// **There is no Accept or Decline here, and there can't be.** No API this
/// app can reach answers an invitation — `EKParticipant.participantStatus`
/// is read-only, so is Calendar's scripted `participation status`, and
/// sending the reply ourselves would need either the network entitlement
/// this app doesn't have or an outgoing mail it will never send. Rather
/// than offer two buttons that only pretend, RSVP stays where it works:
/// "Open in Calendar" is one click from the accept and decline buttons on
/// the invitation itself.
///
/// One popover with pages, like `MailActionPopover`: confirming a delete
/// replaces this panel's contents rather than stacking a second popover on
/// top of the first.
struct MeetingActionPopover: View {
    let meeting: DayMeeting
    let day: Date
    /// What this meeting's series has cost over the last quarter, when it
    /// repeats. Nil for a one-off — an hour that happened once isn't a
    /// decision anyone can make.
    let cost: MeetingCost.Series?
    let onJoin: (URL) -> Void
    let onOpenInCalendar: () -> Void
    let onDelete: (CalendarStore.DeletionScope) -> Void

    private enum Page {
        case actions
        case deleting
    }

    @State private var page: Page = .actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading

            switch page {
            case .actions: actions
            case .deleting: deleting
            }
        }
        .padding(16)
        .frame(width: 300)
        // Back to the list of actions whenever this closes. Without it the
        // confirmation is sticky: dismiss the panel while it's asking, open
        // the same meeting again, and the first thing under your cursor is
        // "Yes, delete it" — which is not where a destructive action should
        // start.
        .onDisappear { page = .actions }
    }

    private var actions: some View {
        VStack(spacing: 4) {
            if let joinURL = meeting.joinURL {
                action("Join the call", symbol: "video.fill") { onJoin(joinURL) }
            }
            action("Open in Calendar", symbol: "calendar", onOpenInCalendar)
            action("Delete from Calendar", symbol: "trash") { page = .deleting }
        }
    }

    /// The second ask. Deleting a meeting is the one irreversible thing
    /// this app does to something it didn't create, and for a repeating
    /// meeting the choice underneath is a real one — so the confirmation
    /// isn't a yes/no, it's which of them you meant.
    private var deleting: some View {
        VStack(alignment: .leading, spacing: 6) {
            if meeting.isRecurring {
                action("Delete just this one", symbol: "trash", tint: .red) { onDelete(.thisOccurrence) }
                action("Delete this and every later one", symbol: "trash", tint: .red) {
                    onDelete(.thisAndLater)
                }
            } else {
                action("Yes, delete it", symbol: "trash", tint: .red) { onDelete(.thisOccurrence) }
            }

            // The thing people would otherwise assume. Deleting an
            // invitation looks like declining it and isn't: the organiser
            // has no way of hearing about this, so a meeting you quietly
            // remove is one you're expected at.
            Text(meeting.organizer == nil
                ? "This can't be undone."
                : "This can't be undone, and it doesn't decline the invitation — the organiser won't be told. Open it in Calendar to reply.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(MeetingTimeFormat.rangeLabel(start: meeting.start, end: meeting.end))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if page != .actions {
                    Button("Back") { page = .actions }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text(meeting.title)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            // The one figure in this app that turns a standing commitment
            // into a number you can decide about. Stated and left alone:
            // there is no advice attached, and in particular no suggestion
            // to decline, which this app cannot do and says so two
            // paragraphs down.
            if let cost, cost.occurrences > 1 {
                Text(costLine(cost))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

    /// "6h since 1 Jun, across 12 of them." Since the first one counted
    /// rather than "this quarter": the window is ninety days, but a
    /// fortnightly meeting that started in July has only been running since
    /// July, and saying otherwise would overstate what it has cost.
    private func costLine(_ cost: MeetingCost.Series) -> String {
        "\(HoursFormat.string(cost.hours)) since \(Self.since.string(from: cost.first)), across \(cost.occurrences) of them."
    }

    private static let since: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

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

    /// One decision: a word, an icon, and the whole width of the panel to
    /// hit it with. Coloured only where it destroys something, so red on
    /// this panel means exactly one thing.
    private func action(
        _ title: String,
        symbol: String,
        tint: Color = .primary,
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
            .foregroundStyle(tint)
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
