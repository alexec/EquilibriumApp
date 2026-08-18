import SwiftUI

/// Apple Health-style vertical bar chart: one pill-shaped bar per day from
/// start-of-work to end-of-work time, scaled from 6am to midnight. Day
/// columns stretch to fill the available width. Each meeting is a
/// real-time-positioned block you can drag by its top edge, bottom edge, or
/// middle; hover a day to reveal Delete / Reset-meetings buttons.
///
/// `days` is exactly one Sat-Fri week — the same unit the weekly target,
/// the recommendation and the weekly summary all work in. Showing one week
/// rather than two is what pays for the bar width: seven columns in the
/// space fourteen used to share, wide enough to drag a meeting block
/// without hunting for it.
struct DailyBarChartView: View {
    let days: [Date]
    let spans: [WorkdaySpan?]
    let recommendedHours: (Date) -> Double?
    /// The configured workday span (from `WorkPreferences`), passed through
    /// to each day's `DayBar` for its "normal workday" track.
    let workdayStartHour: Double
    let workdayEndHour: Double
    /// The configured weekly target (from `WorkPreferences`), used only for
    /// the fallback week-header sentence's target comparison basis.
    let weeklyTargetHours: Double
    /// LLM-generated "You worked ..." caption for the week starting on the
    /// given date, or nil if unavailable/not generated yet — in which case
    /// the deterministic `WeekHeaderStats.fallbackSentence` is shown instead.
    let aiWeekSummary: (Date) -> String?
    /// Week navigation, rendered as ‹ › either side of `weekLabel`.
    let weekLabel: String
    let canShowPreviousWeek: Bool
    let canShowNextWeek: Bool
    let onShowPreviousWeek: () -> Void
    let onShowNextWeek: () -> Void
    /// That day's intention / check-in, or nil if nothing's recorded — this
    /// is what fills in the buttons above and below each bar.
    let intention: (Date) -> DailyIntention?
    /// The day the side panel is showing, so its column's button can show
    /// as selected.
    let selection: DayEditorSelection
    let onSelectDay: (Date, DailyPromptKind) -> Void
    let onMeetingChange: (Date, UUID, Date, Date) -> Void
    let onWorkdayChange: (Date, Date, Date) -> Void
    let onResetMeetings: (Date) -> Void
    let onDelete: (Date) -> Void

    @State private var hoveringDay: Date?
    /// Which side the week being moved to slides in from; see `page(_:)`.
    @State private var insertionEdge: Edge = .trailing

    static let minimumHeight: CGFloat = 220
    /// Weekday and date, stacked above each column — two points taller
    /// than the text alone needs, for the capsule drawn round today's date.
    private static let labelHeight: CGFloat = 29
    /// The day's total, under the check-in moon.
    private static let totalHeight: CGFloat = 13
    /// The hover-revealed delete / reset row under each column.
    private static let columnControlsHeight: CGFloat = 12
    /// Gap between the pieces of a day's column.
    private static let columnStackSpacing: CGFloat = 2
    /// Gap between the week header and the columns beneath it.
    private static let headerGap: CGFloat = 4

    /// Everything in a column that isn't the bar: the labels above and
    /// below, both prompt buttons with their padding, the controls row, and
    /// the five gaps between the six of them. Counted in one place because
    /// the bar gets whatever is left, and an undercount here makes every
    /// column taller than the space it was given.
    private static var columnOverhead: CGFloat {
        labelHeight + totalHeight + columnControlsHeight
            + (promptRowHeight + columnSpacing - 2) * 2
            + columnStackSpacing * 5
    }

    /// How far below the top of a column its bar begins — the y-axis labels
    /// drop by the same amount so they keep pointing at the right heights.
    private static var barTopInset: CGFloat {
        labelHeight + columnStackSpacing
            + promptRowHeight + (columnSpacing - 2)
            + columnStackSpacing
    }
    // The intention button sits above each bar and the check-in below it,
    // one row of this height each, taken off the bars' own height.
    private static let promptRowHeight: CGFloat = 16
    // Fits the week navigation row plus the stats sentence below it, which
    // can still wrap to two lines at the narrowest window width.
    private static let weekHeaderHeight: CGFloat = 46
    private static let yAxisWidth: CGFloat = 36
    private static let yAxisHours: [Double] = [6, 9, 12, 15, 18, 21]
    // Seven columns rather than fourteen: even at the narrowest the window
    // is allowed to get (see `EquilibriumApp`'s frame), a column has room
    // for this bar plus its 10pt workday track and still clears its
    // neighbours.
    private static let barWidth: CGFloat = 18
    private static let columnSpacing: CGFloat = 4

    private func isWeekend(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        return weekday == 1 || weekday == 7 // Sunday or Saturday
    }

    private func yAxisLabel(_ hour: Double) -> String {
        let period = hour < 12 || hour == 24 ? "AM" : "PM"
        let displayHour = hour == 0 || hour == 24 ? 12 : (hour > 12 ? hour - 12 : hour)
        return "\(Int(displayHour)) \(period)"
    }

    /// The header line for the visible week: the LLM-generated caption when
    /// one's available, else the deterministic "Nh meetings/day, ..."
    /// sentence built from the same `WeekHeaderStats`. Nil when the week has
    /// no data at all yet.
    private var weekHeaderLine: String? {
        guard let weekStart = days.first,
              let stats = WeeklyInsightGenerator.WeekHeaderStats.compute(from: spans, weeklyTargetHours: weeklyTargetHours) else { return nil }
        return aiWeekSummary(weekStart) ?? stats.fallbackSentence
    }

    var body: some View {
        GeometryReader { geo in
            let chartHeight = geo.size.height
                - Self.weekHeaderHeight - Self.headerGap - Self.columnOverhead

            VStack(alignment: .leading, spacing: Self.headerGap) {
                weekAverageHeader

                HStack(alignment: .top, spacing: 6) {
                    YAxisView(
                        hours: Self.yAxisHours,
                        chartHeight: chartHeight,
                        width: Self.yAxisWidth,
                        label: yAxisLabel
                    )
                    .padding(.top, Self.barTopInset)

                    dayColumns(chartHeight: chartHeight)
                        // Identity tied to the week, so changing week is an
                        // insertion and a removal that can slide past each
                        // other rather than bars silently swapping values.
                        .id(days.first)
                        .transition(.asymmetric(
                            insertion: .move(edge: insertionEdge).combined(with: .opacity),
                            removal: .move(edge: insertionEdge == .leading ? .trailing : .leading).combined(with: .opacity)
                        ))
                }
                // The outgoing week travels beyond the chart's edges on its
                // way out; without this it would be drawn over the window.
                .clipped()
            }
        }
        .frame(minHeight: Self.minimumHeight)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.06))
        )
        .onWeekSwipe(page)
    }

    /// Every route to another week — chevrons, ⌘[ / ⌘], swipe — goes
    /// through here, so they all animate the same way. The edge is set
    /// first: the incoming week arrives from the side it lives on, left for
    /// earlier weeks and right for later ones, which is what makes a swipe
    /// feel like it's dragging the calendar rather than replacing it.
    private func page(_ direction: WeekSwipeDirection) {
        insertionEdge = direction == .previous ? .leading : .trailing
        withAnimation(.easeInOut(duration: 0.25)) {
            switch direction {
            case .previous: onShowPreviousWeek()
            case .next: onShowNextWeek()
            }
        }
    }

    /// Week navigation, with the week's caption underneath it. The caption
    /// now has the chart's full width instead of half of it, so it reads at
    /// a normal size rather than the shrunk-to-fit 9pt the two-week layout
    /// needed.
    private var weekAverageHeader: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                weekStepButton("chevron.left", label: "Previous week", enabled: canShowPreviousWeek) { page(.previous) }
                    .keyboardShortcut("[", modifiers: .command)
                Text(weekLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 96)
                weekStepButton("chevron.right", label: "Next week", enabled: canShowNextWeek) { page(.next) }
                    .keyboardShortcut("]", modifiers: .command)
            }

            if let weekHeaderLine {
                // Cross-fades rather than sliding: the sentence is about the
                // week arriving, and sliding it alongside the bars would put
                // two different weeks' words on screen at once.
                Text(weekHeaderLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .id(days.first)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// `label` names the button for VoiceOver as well as the tooltip: the
    /// chevrons carry no text of their own, so without it they're announced
    /// only as unlabelled buttons.
    private func weekStepButton(
        _ systemName: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                // Kept in the layout when it can't be used, so the label
                // beside it doesn't shift as you page to either end.
                .foregroundColor(enabled ? .secondary : .secondary.opacity(0.25))
                .contentShape(Rectangle())
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }

    /// Weekday and date above the column, where a calendar puts them —
    /// with today's date in a filled capsule and its weekday in full
    /// strength, the way a calendar marks the current date.
    ///
    /// Without it the only clue which column is now is which one still has
    /// hours in it, and that reads wrong exactly when it matters: before
    /// the day's first work is recorded, today is indistinguishable from
    /// tomorrow, both of them an empty track under a row of meetings.
    ///
    /// A capsule rather than a circle because `dateLabel` is sometimes a
    /// month as well as a number, and a circle round "Aug 18" is an oval
    /// pretending otherwise. The padding is applied on every day so that
    /// midnight, which moves the capsule one column along, doesn't also
    /// shift the labels either side of it.
    private func columnHeader(day: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(day)

        return VStack(spacing: 1) {
            Text(weekdayLabel(day))
                .font(.system(size: 11, weight: isToday ? .semibold : .medium))
                .foregroundColor(isToday ? .primary : .secondary)
            Text(dateLabel(day))
                .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                .foregroundColor(isToday ? .white : .secondary.opacity(0.7))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(isToday ? Color.accentColor : .clear))
        }
        .frame(height: Self.labelHeight, alignment: .top)
        // The capsule is colour alone, which VoiceOver doesn't see; the
        // date is read out either way, so this only has to add the word.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isToday
                ? "Today, \(Self.accessibilityDayFormatter.string(from: day))"
                : Self.accessibilityDayFormatter.string(from: day)
        )
    }

    /// The day's total, under the check-in moon: the date says which day
    /// this is, and this says what it came to — the two ends of the column.
    ///
    /// Its line is reserved on days without one so that what sits below it
    /// keeps a common baseline across the week.
    private func columnTotal(day: Date, span: WorkdaySpan?) -> some View {
        Group {
            if let hours = span?.roundedUpHours, (span?.hours ?? 0) > 0 {
                Text("\(hours)h")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DayFire.intensity(hours: hours, isWeekend: isWeekend(day)) > 0 ? .red : .secondary)
            } else {
                Text(" ")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .frame(height: Self.totalHeight)
    }

    /// A day's intention (above its bar) or check-in (below it): a sun for
    /// the morning and a moon for the evening, filled once something's been
    /// written and hollow while it hasn't. Clicking opens that day in the
    /// side panel — including days long past, which is the point of putting
    /// these on every column rather than only on today.
    @ViewBuilder
    private func promptButton(day: Date, kind: DailyPromptKind) -> some View {
        let entry = intention(day)
        let isFilled = kind == .intention ? (entry?.hasIntention ?? false) : (entry?.hasCheckIn ?? false)
        let isSelected = selection == DayEditorSelection(day: Calendar.current.startOfDay(for: day), kind: kind)
        // A day that hasn't happened has nothing to check in about; its
        // intention is still worth setting in advance, so only this half
        // disappears — as an empty slot, so the bars stay aligned.
        let isAvailable = kind == .intention || day <= Calendar.current.startOfDay(for: Date())

        if isAvailable {
            Button {
                onSelectDay(day, kind)
            } label: {
                Image(systemName: symbolName(kind: kind, filled: isFilled))
                    .font(.system(size: 10, weight: .medium))
                    // Filled in the text colour rather than the accent:
                    // the accent now means "this is the day you're looking
                    // at" — the capsule on today and the band behind the
                    // selected column — and a sun wearing it too would be
                    // a third meaning for the same colour.
                    .foregroundColor(isFilled ? .primary : .secondary.opacity(0.4))
                    .frame(width: Self.promptRowHeight, height: Self.promptRowHeight)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(helpText(kind: kind, filled: isFilled))
            // Pointer users have the column under the cursor for context;
            // VoiceOver has nothing, so the label names the day as well as
            // what the button does.
            .accessibilityLabel("\(helpText(kind: kind, filled: isFilled)), \(Self.accessibilityDayFormatter.string(from: day))")
        } else {
            Color.clear.frame(height: Self.promptRowHeight)
        }
    }

    private func symbolName(kind: DailyPromptKind, filled: Bool) -> String {
        switch kind {
        case .intention: return filled ? "sun.max.fill" : "sun.max"
        case .checkIn: return filled ? "moon.fill" : "moon"
        }
    }

    private static let accessibilityDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter
    }()

    private func helpText(kind: DailyPromptKind, filled: Bool) -> String {
        switch kind {
        case .intention: return filled ? "Edit this day's intention" : "Set an intention for this day"
        case .checkIn: return filled ? "Edit this day's check-in" : "Check in on this day"
        }
    }

    private func dayColumns(chartHeight: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Self.columnSpacing) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                dayColumn(day: day, index: index, chartHeight: chartHeight)
            }
        }
    }

    /// One day's column. A band behind the whole of it marks the day the
    /// side panel is showing: the accent ring on a 16pt sun says which
    /// *prompt* is open but is far too small to say which day, so the panel
    /// could sit on Thursday's check-in with nothing on the chart admitting
    /// it. Band for the day, ring for the prompt — two jobs, two marks.
    private func dayColumn(day: Date, index: Int, chartHeight: CGFloat) -> some View {
        let span = spans[index]
        let isHovering = hoveringDay == day
        let isSelected = Calendar.current.isDate(selection.day, inSameDayAs: day)

        return VStack(spacing: Self.columnStackSpacing) {
            columnHeader(day: day)

            promptButton(day: day, kind: .intention)
                .padding(.bottom, Self.columnSpacing - 2)

            DayBar(
                span: span,
                day: day,
                chartHeight: chartHeight,
                isWeekend: isWeekend(day),
                barWidth: Self.barWidth,
                showsWorkdayTrack: true,
                showsHoursLabel: true,
                recommendedHours: recommendedHours(day),
                workdayStartHour: workdayStartHour,
                workdayEndHour: workdayEndHour,
                onMeetingChange: { meetingID, newStart, newEnd in
                    onMeetingChange(day, meetingID, newStart, newEnd)
                },
                onWorkdayChange: { newStart, newEnd in
                    onWorkdayChange(day, newStart, newEnd)
                }
            )

            promptButton(day: day, kind: .checkIn)
                .padding(.top, Self.columnSpacing - 2)

            columnTotal(day: day, span: span)

            // Delete / Reset-meetings buttons, revealed on hover so the bar
            // itself (only ~10pt wide) doesn't need to host them.
            HStack(spacing: 8) {
                if span?.meetingsManuallyEdited == true {
                    Button {
                        onResetMeetings(day)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .help("Reset meetings to calendar data")
                }
                if (span?.hours ?? 0) > 0 {
                    Button {
                        onDelete(day)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete this day's hours")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .opacity(isHovering ? 1 : 0)
            .frame(height: 12)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(isSelected ? 0.1 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveringDay = hovering ? day : (hoveringDay == day ? nil : hoveringDay)
        }
    }

    private func weekdayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    /// Day-of-month number, with the month abbreviation appended on the
    /// first day of a month (or the first visible column) so scrolling
    /// through weeks shows where a new month begins.
    private func dateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: date)
        let isMonthBoundary = day == 1 || date == days.first

        if isMonthBoundary {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
        return "\(day)"
    }
}
