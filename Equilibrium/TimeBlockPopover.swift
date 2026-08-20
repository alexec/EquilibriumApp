import SwiftUI

/// Turning a message into time in the diary.
///
/// The gap this closes is the one between knowing what to do and having
/// somewhere to do it. A summary that says "send the bank statement" and a
/// week with no space in it produces the same outcome as no summary at all;
/// this puts the work somewhere before the deadline the message came with.
///
/// **Only this week.** The days offered run from today to Friday and no
/// further. Equilibrium is a week at a time — the chart, the target, the
/// review — and time blocked into next week isn't a plan, it's a deferral
/// wearing a hat; there's a Defer button for that, two rows up. If the work
/// won't fit before Friday, that's worth learning now.
///
/// It recommends *and* lets you argue. The slot comes from
/// `TimeBlockPlanner`, already chosen, so the common case is one click —
/// but the day and the hour are both there to be overruled, because the
/// planner knows what's free and you know that Thursday morning is when
/// you think clearly.
struct TimeBlockPopover: View {
    let dueDate: Date?
    /// The recommendation for a given length.
    let slot: (Int) -> TimeBlockPlanner.Slot?
    /// The days that can be chosen: what's left of this week.
    let days: [Date]
    /// The start times available on a day, and whether each is free.
    let startTimes: (Date, Int) -> [(start: Date, isFree: Bool)]
    let onAdd: (TimeBlockPlanner.Slot, Int) -> Bool

    @State private var minutes = TimeBlockPlanner.defaultMinutes
    @State private var day: Date?
    @State private var start: Date?
    /// Whether the choice on screen is the reader's or the planner's. The
    /// recommendation should follow the length being changed; a time
    /// someone picked should not be quietly overwritten because they then
    /// changed the length.
    @State private var isMine = false
    @State private var added: TimeBlockPlanner.Slot?
    @State private var failed = false

    private static let lengths = [30, 60, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let added {
                confirmation(added)
            } else if days.isEmpty {
                Text("There's no working time left this week.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                lengthPicker
                dayPicker
                hourPicker
                summary
            }

            if failed {
                Text("Couldn't add it — no calendar here can be written to.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: seed)
        .onChange(of: minutes) { _ in
            // A longer block may not fit where a shorter one did, so the
            // planner is asked again — unless the choice is the reader's,
            // in which case only the times on offer change.
            guard !isMine else { return }
            seed()
        }
    }

    /// Fills in the planner's answer, or the first day and time available
    /// when it hasn't got one — a picker that opens empty because the week
    /// is busy is the least useful thing on screen.
    private func seed() {
        if let recommended = slot(minutes) {
            day = Calendar.current.startOfDay(for: recommended.start)
            start = recommended.start
            return
        }
        guard start == nil else { return }
        let firstDay = days.first
        day = firstDay
        start = firstDay.flatMap { startTimes($0, minutes).first(where: \.isFree)?.start }
            ?? firstDay.flatMap { startTimes($0, minutes).first?.start }
    }

    private var lengthPicker: some View {
        Picker("", selection: $minutes) {
            ForEach(Self.lengths, id: \.self) { length in
                Text("\(length)m").tag(length)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
    }

    /// The rest of the week, a chip each.
    private var dayPicker: some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(days, id: \.timeIntervalSinceReferenceDate) { candidate in
                chip(
                    Self.dayName(candidate),
                    selected: isSameDay(candidate, day),
                    free: true
                ) {
                    day = Calendar.current.startOfDay(for: candidate)
                    isMine = true
                    // The old time belonged to another day; take the first
                    // free one here rather than leaving a stale selection.
                    start = startTimes(candidate, minutes).first(where: \.isFree)?.start
                        ?? startTimes(candidate, minutes).first?.start
                }
            }
        }
    }

    /// The half hours that day has room for. Taken ones stay on the list,
    /// marked — a day with something in every slot should say so rather
    /// than show nothing.
    @ViewBuilder
    private var hourPicker: some View {
        if let day {
            let times = startTimes(day, minutes)
            if times.isEmpty {
                Text("Nothing fits in your working hours that day.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    FlowLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(times, id: \.start.timeIntervalSinceReferenceDate) { time in
                            chip(
                                MeetingTimeFormat.compactTime(time.start),
                                selected: start == time.start,
                                free: time.isFree
                            ) {
                                start = time.start
                                isMine = true
                            }
                        }
                    }
                }
                .frame(maxHeight: 108)
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let start {
            let chosen = TimeBlockPlanner.Slot(
                start: start,
                end: start.addingTimeInterval(TimeInterval(minutes * 60))
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.describe(chosen))
                    .font(.system(size: 12, weight: .medium))

                if let dueDate, chosen.start > dueDate {
                    // Worth saying and not worth preventing: you may well
                    // mean to, and this is the only place it's visible.
                    Text("After this is due (\(Self.day.string(from: dueDate))).")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.orange)
                }

                Button("Add to calendar") {
                    if onAdd(chosen, minutes) {
                        added = chosen
                    } else {
                        failed = true
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// One choice. Taken slots are shown struck through rather than hidden
    /// or disabled: knowing that two o'clock is spoken for is the reason
    /// you pick three.
    private func chip(
        _ title: String,
        selected: Bool,
        free: Bool,
        _ perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .strikethrough(!free, color: .secondary)
                .foregroundStyle(selected ? Color.white : (free ? Color.primary : Color.secondary))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(
                        selected ? Color.accentColor : Color.secondary.opacity(free ? 0.12 : 0.06)
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(free ? "" : "Something else is already there")
    }

    private func confirmation(_ slot: TimeBlockPlanner.Slot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(Self.describe(slot), systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            // Says what kind of event it made, because the distinction is
            // the whole point: this time is busy to everyone looking for a
            // slot, and still not a meeting as far as your week's figures
            // are concerned.
            Text("Added as focus time, not a meeting.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func isSameDay(_ left: Date, _ right: Date?) -> Bool {
        guard let right else { return false }
        return Calendar.current.isDate(left, inSameDayAs: right)
    }

    /// "Today", "Tomorrow", then the weekday — the shortest thing that
    /// still places the day.
    static func dayName(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return weekday.string(from: date)
    }

    /// "Tomorrow, 9:00 – 10:00".
    static func describe(_ slot: TimeBlockPlanner.Slot) -> String {
        "\(dayName(slot.start)), \(MeetingTimeFormat.rangeLabel(start: slot.start, end: slot.end))"
    }

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}
