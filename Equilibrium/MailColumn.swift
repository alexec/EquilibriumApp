import SwiftUI

/// The inbox, to the left of the week.
///
/// Not a mail client, and the difference is the point: no message is shown,
/// only what it asks of you. The calendar column beside it already works
/// this way — a meeting is a block of time and a title, not an invitation —
/// and mail earns its place here on the same terms. Planning a day means
/// knowing what's waiting, not reading it.
struct MailColumn: View {
    let messages: [MailMessage]
    let summary: (MailMessage) -> MailSummary?
    let access: MailAccessState
    /// The model's line about the day, when there is one.
    let brief: String?
    /// What you said you'd get done, then the counts. Always shown, and the
    /// whole of this on a Mac with no on-device model.
    let briefFallback: String
    /// Who the window is being read through, when a chip in the people
    /// strip has been pressed. The column only needs it to explain an empty
    /// list: "nothing in the inbox" and "nothing from this person" are very
    /// different pieces of news.
    let focusedName: String?
    let onRefresh: () -> Void
    let onOpen: (MailMessage) -> Void
    let recommendedBlock: (MailMessage, Int) -> TimeBlockPlanner.Slot?
    let blockableDays: [Date]
    let blockStartTimes: (Date, Int) -> [(start: Date, isFree: Bool)]
    let onBlockTime: (MailMessage, TimeBlockPlanner.Slot) -> Bool
    let onArchive: (MailMessage) -> Void
    /// Why the last archive didn't happen, when it didn't.
    let archiveProblem: String?
    let deferralDate: (MailMessage) -> Date?
    let onDefer: (MailMessage, Date) -> Void
    let onUndefer: (MailMessage) -> Void
    let deferredCount: Int
    @Binding var showsDeferred: Bool

    var body: some View {
        card
            .frame(width: SideColumn.width, alignment: .leading)
    }

    /// The same very light card as the chart and the day panel. Three
    /// columns of loose text with nothing behind them read as three
    /// unrelated things; on matching cards they read as one window.
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Above the header, not under it, and shown whether or not the
            // inbox has anything in it: this line leads with what you said
            // you'd get done today, which is the first thing in the window
            // worth reading and isn't about the inbox at all. Under the
            // "Inbox" title it read as a fact about the mail.
            briefBlock
            header

            if messages.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if access == .denied {
                    // A prompt answered weeks ago and one never shown look
                    // identical from here. Saying where the switch lives
                    // costs a line and saves a hunt — the same reasoning as
                    // the calendar's message in `DayDetailPanel`.
                    Text("System Settings › Privacy & Security › Automation")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            } else {
                deferredToggle
                if let archiveProblem {
                    Text(archiveProblem)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            MailRow(
                                message: message,
                                summary: summary(message),
                                deferredUntil: deferralDate(message),
                                onDefer: { onDefer(message, $0) },
                                onUndefer: { onUndefer(message) },
                                onOpen: { onOpen(message) },
                                recommendedBlock: { recommendedBlock(message, $0) },
                                blockableDays: blockableDays,
                                blockStartTimes: blockStartTimes,
                                onBlockTime: { onBlockTime(message, $0) },
                                onArchive: { onArchive(message) }
                            )
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            // No gap for the traffic lights here, though this is the
            // leftmost column and they do overlap the card. Only the card's
            // *background* passes behind them: the window's padding and the
            // card's own put this row below the cluster already, so the
            // clearance that used to sit here bought nothing and pushed the
            // title into the middle of the card, where it read as badly
            // centred against the left-aligned heading in the day panel.
            Image(systemName: "tray")
                .font(.system(size: 10))
            Text("Inbox")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Read the inbox again")
        }
        .foregroundStyle(.secondary)
    }

    /// What today is likely to ask of you, over your own words and the
    /// counts they sit with. The lower line stays put whether or not
    /// there's a generated one above it — it's the part that's always true,
    /// and on a Mac with no on-device model it's all there is.
    ///
    /// The two never say the same thing twice: the model is told to refer
    /// to the intention rather than repeat it, and a brief that hands it
    /// back is thrown away (`DayBriefGenerator.echoesGoal`).
    @ViewBuilder
    private var briefBlock: some View {
        if brief != nil || !briefFallback.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let brief {
                    Text(brief)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !briefFallback.isEmpty {
                    Text(briefFallback)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The way back to what's been put off.
    ///
    /// Deferred mail is out of the way rather than gone, and this line is
    /// the proof — without it, choosing "next week" means watching a
    /// message vanish and having to trust that it will return.
    @ViewBuilder
    private var deferredToggle: some View {
        if deferredCount > 0 || showsDeferred {
            Button {
                showsDeferred.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showsDeferred ? "eye.slash" : "clock.arrow.circlepath")
                        .font(.system(size: 9))
                    Text(showsDeferred ? "Hide deferred" : "\(deferredCount) deferred")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// Why the column is empty. "Nothing this week" is a fact about the
    /// inbox; the other two are facts about the app.
    private var emptyMessage: String {
        if let focusedName, access == .granted {
            return "Nothing from \(focusedName) in the inbox."
        }
        switch access {
        case .granted: return "Nothing in the inbox this week."
        case .pending: return "Reading your inbox…"
        case .denied: return "Equilibrium isn't allowed to read Mail, so the inbox isn't shown."
        case .unavailable: return "Mail didn't answer. Trying again shortly."
        }
    }
}

/// One message: who it's from, what it's about, and what it wants.
private struct MailRow: View {
    let message: MailMessage
    let summary: MailSummary?
    /// When this was put off until, if it was.
    let deferredUntil: Date?
    let onDefer: (Date) -> Void
    let onUndefer: () -> Void
    let onOpen: () -> Void
    let recommendedBlock: (Int) -> TimeBlockPlanner.Slot?
    let blockableDays: [Date]
    let blockStartTimes: (Date, Int) -> [(start: Date, isFree: Bool)]
    let onBlockTime: (TimeBlockPlanner.Slot) -> Bool
    let onArchive: () -> Void

    @State private var isHovering = false
    @State private var showsActions = false

    /// The whole row is one target, and it opens the actions rather than
    /// the message.
    ///
    /// It used to carry three 11-point icons, which were the right size for
    /// a toolbar and the wrong size for something you aim at forty times a
    /// day. And opening Mail was the wrong default: most of what you do
    /// with a row is decide about it — later, block time, done — and only
    /// sometimes read it. So the click opens a popover where all four are
    /// full-width, labelled, and impossible to miss, with the message's own
    /// gist above them so the decision usually doesn't need Mail at all.
    var body: some View {
        Button {
            showsActions = true
        } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .popover(isPresented: $showsActions, arrowEdge: .trailing) {
            MailActionPopover(
                message: message,
                summary: summary,
                deferredUntil: deferredUntil,
                recommendedBlock: recommendedBlock,
                blockableDays: blockableDays,
                blockStartTimes: blockStartTimes,
                onBlockTime: onBlockTime,
                onDefer: { onDefer($0); showsActions = false },
                onUndefer: { onUndefer(); showsActions = false },
                onArchive: { onArchive(); showsActions = false },
                onOpen: { onOpen(); showsActions = false }
            )
        }
    }

    /// Who it's from, what it's about, and what it wants.
    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ParticipantLabel(primary: message.sender, others: message.recipients)
                Spacer(minLength: 4)
                Text(MailRow.received.string(from: message.receivedAt))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 5) {
                // The unread dot sits with the subject rather than the
                // sender: it's the message that's unread, and on a row
                // whose first line is a name it reads as being about them.
                if message.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .padding(.top, 5)
                }
                Text(message.displaySubject)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The action line, where the model produced one worth keeping.
            // Its absence is ordinary — most Macs can't run the model at
            // all — so the row above it has to stand on its own, and does.
            if let action = summary?.action, !action.isEmpty {
                Text(action)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 4) {
                if let due = summary?.dueDate {
                    DueLabel(date: due)
                }
                if let deferredUntil {
                    DeferLabel(date: deferredUntil)
                }
            }
        }
    }

    /// Day and time, not a full date: everything here arrived this week.
    private static let received: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()
}

/// A message you put off.
///
/// Two states, because they mean opposite things. Still waiting, and it
/// says when it's coming back. Come due, and it says so — a message
/// reappearing in a column you'd cleared should explain itself rather than
/// look like it was never dealt with. Taking the deferral back is in the
/// row's popover, where the other decisions are.
private struct DeferLabel: View {
    let date: Date

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Color.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private var text: String {
        if MailDeferral.isDueNow(date) { return "back today" }
        if Calendar.current.isDateInTomorrow(date) { return "later: tomorrow" }
        return "later: \(DeferLabel.day.string(from: date))"
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}

/// "due today", "due Thu" — the deadline the detector found, said in the
/// fewest words that still place it.
private struct DueLabel: View {
    let date: Date

    /// Blue, not orange, for the deadline that's already here.
    ///
    /// Orange reads as a warning, and a column of warnings is a column you
    /// stop looking at. A due date is information, not an alarm: this app
    /// exists to make a week legible, and the thing it should not do is add
    /// to the pressure of the week it's describing. The emphasis still
    /// marks today's deadlines out from the rest — it just doesn't shout.
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isUrgent ? Color.blue : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill((isUrgent ? Color.blue : Color.secondary).opacity(0.12))
            )
    }

    private var isUrgent: Bool {
        Calendar.current.isDateInToday(date) || date < Date()
    }

    private var text: String {
        let calendar = Calendar.current
        if date < Date(), !calendar.isDateInToday(date) { return "overdue" }
        if calendar.isDateInToday(date) { return "due today" }
        if calendar.isDateInTomorrow(date) { return "due tomorrow" }
        return "due \(DueLabel.weekday.string(from: date))"
    }

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}
