import SwiftUI

/// The view shown inside the `MenuBarExtra` popover: today's hours worked,
/// the remaining weekly budget, what's left of the day's diary, and a way
/// into the main window.
///
/// The menu bar itself has room for one meeting; this is where the rest of
/// them go, with their full titles rather than the sixteen characters that
/// fit up there.
struct MenuBarStatusView: View {
    @ObservedObject var viewModel: WorkHistoryViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                statView(label: "Today", value: todayHoursText)
                Divider().frame(height: 32)
                statView(label: "Remaining", value: remainingText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            remainingMeetings
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            Divider()

            Button("Open Equilibrium") {
                MainWindow.present { openWindow(id: "main") }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 260)
    }

    /// What's left of the day, in the order you'll meet it. The one in
    /// progress is marked "now" rather than given a start time already gone
    /// past — the same distinction the menu bar makes.
    @ViewBuilder
    private var remainingMeetings: some View {
        let meetings = viewModel.remainingMeetingsToday

        VStack(alignment: .leading, spacing: 5) {
            Text("Rest of today")
                .font(.caption)
                .foregroundStyle(.secondary)

            if meetings.isEmpty {
                Text(viewModel.calendarAccessGranted
                     ? "Nothing else in the diary."
                     : "Calendar access is off.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(meetings.prefix(Self.meetingLimit)) { meeting in
                    meetingRow(meeting)
                }
                // A day with a dozen meetings shouldn't make a popover the
                // height of the screen; the chart's panel has the full list.
                if meetings.count > Self.meetingLimit {
                    Text("+\(meetings.count - Self.meetingLimit) more")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A meeting: its time, its title, and the call if it has one.
    ///
    /// Two targets rather than one, because there are two things you want
    /// from a meeting in a hurry and they aren't the same thing. The row
    /// opens the event in Calendar, where the agenda and the other guests
    /// are; the camera joins the call.
    private func meetingRow(_ meeting: DayMeeting) -> some View {
        let now = viewModel.isInProgress(meeting)

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                MeetingLinks.showInCalendar(identifier: meeting.eventIdentifier, on: meeting.start)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(now ? "now" : MeetingTimeFormat.compactTime(meeting.start))
                        .font(.system(size: 11, weight: now ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(now ? Color.accentColor : Color.secondary)
                        .frame(width: 46, alignment: .leading)
                    Text(meeting.title)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show in Calendar")

            if let joinURL = meeting.joinURL {
                Button {
                    MeetingLinks.join(joinURL)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Join \(joinURL.host ?? "the call")")
                .accessibilityLabel("Join \(meeting.title)")
            }
        }
    }

    private static let meetingLimit = 6

    // MARK: - Helpers

    private var todayHoursText: String {
        let hours = viewModel.span(for: Date())?.effectiveHours ?? 0
        return HoursFormat.string(hours)
    }

    private var remainingText: String {
        let remaining = viewModel.remainingWeeklyHours()
        if remaining >= 0 {
            return HoursFormat.string(remaining)
        } else {
            return "+\(HoursFormat.string(-remaining))"
        }
    }

    private func statView(label: String, value: String) -> some View {
        VStack(alignment: .center, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
