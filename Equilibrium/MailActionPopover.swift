import SwiftUI

/// What you can do about one message, on one panel.
///
/// This replaced three icons sitting in the row itself. They were eleven
/// points across, they had to be aimed at, and the one that was easiest to
/// hit — the row behind them — opened Mail, which is the thing you least
/// often want. Here every action is a full-width target with a word on it,
/// and the message's own gist sits above them, so the common case is that
/// you decide from this panel and never open the message at all.
///
/// One popover with pages, not popovers inside popovers: choosing a day to
/// defer to, or a slot to block, replaces this panel's contents rather than
/// opening a second one on top of it.
struct MailActionPopover: View {
    let message: MailMessage
    let summary: MailSummary?
    let deferredUntil: Date?
    let recommendedBlock: (Int) -> TimeBlockPlanner.Slot?
    let blockableDays: [Date]
    let blockStartTimes: (Date, Int) -> [(start: Date, isFree: Bool)]
    let onBlockTime: (TimeBlockPlanner.Slot) -> Bool
    let onDefer: (Date) -> Void
    let onUndefer: () -> Void
    let onArchive: () -> Void
    let onOpen: () -> Void

    private enum Page {
        case actions
        case deferring
        case blocking
    }

    @State private var page: Page = .actions
    @State private var customDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading

            switch page {
            case .actions: actions
            case .deferring: deferring
            case .blocking: blocking
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ParticipantLabel(primary: message.sender, others: message.recipients, limit: 26)
                Spacer(minLength: 4)
                if page != .actions {
                    Button("Back") { page = .actions }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Text(message.displaySubject)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            // What the message says, so the decision underneath can be made
            // here. Absent on a Mac with no on-device model, and absent when
            // what came back didn't survive checking — which is why nothing
            // below depends on it.
            if let gist = summary?.gist, !gist.isEmpty {
                Text(gist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let deferredUntil {
                Text(MailDeferral.isDueNow(deferredUntil)
                    ? "You put this off until today."
                    : "Put off until \(Self.day.string(from: deferredUntil)).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Pages

    private var actions: some View {
        VStack(spacing: 4) {
            if deferredUntil == nil {
                action("Deal with it later", symbol: "clock") { page = .deferring }
            } else {
                action("Stop deferring", symbol: "clock.badge.xmark", onUndefer)
            }
            action("Block time for it", symbol: "calendar.badge.plus") { page = .blocking }
            action("Archive", symbol: "archivebox", onArchive)
            // Last, because it's the least common thing to want and the most
            // disruptive: it takes you out of the app you were planning in.
            action("Read it in Mail", symbol: "envelope.open", onOpen)
        }
    }

    private var deferring: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MailDeferral.Choice.allCases) { choice in
                action(choice.rawValue, symbol: "clock") { onDefer(choice.date()) }
            }

            Divider()
                .padding(.vertical, 2)

            DatePicker("", selection: $customDate, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
                .controlSize(.small)

            action("Defer to that day", symbol: "calendar") { onDefer(customDate) }

            Text("Adds a reminder in Reminders and flags the message in Mail.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var blocking: some View {
        TimeBlockPopover(
            dueDate: summary?.dueDate,
            slot: recommendedBlock,
            days: blockableDays,
            startTimes: blockStartTimes,
            onAdd: { slot, _ in onBlockTime(slot) }
        )
    }

    /// One decision: a word, an icon, and the whole width of the panel to
    /// hit it with.
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
        .buttonStyle(HighlightingButtonStyle())
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}

/// Fills in behind a row on hover, so a full-width target looks like one.
private struct HighlightingButtonStyle: ButtonStyle {
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
