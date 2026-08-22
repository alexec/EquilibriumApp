import SwiftUI

/// Apple Health-style vertical bar chart: one pill-shaped bar per day from
/// start-of-work to end-of-work time, scaled from 6am to midnight. Day
/// columns stretch to fill the available width. Each meeting is a
/// real-time-positioned block you can drag by its top edge, bottom edge, or
/// middle, and hover to find out which meeting it is; hover a day to reveal
/// Delete / Reset-meetings buttons.
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
    /// A day's calendar meetings, titles and all, for the hover tooltip on
    /// its meeting capsules. A closure rather than a prepared array because
    /// it's a cache lookup in the view model (`chartMeetings(for:)`) and the
    /// chart already asks that way for the recommendation above.
    let meetings: (Date) -> [DayMeeting]
    /// The configured shift slots (from `WorkPreferences`), passed through
    /// to each day's `DayBar` for the ghost outlines it offers.
    let shiftTemplates: [ShiftTemplate]
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
    /// The day the side panel is showing, so its column can be banded as
    /// the selected one.
    let selection: DayEditorSelection
    /// Open a day in the side panel. Which of the day's two sections gets
    /// focus is no longer the chart's business — a column says which day,
    /// and nothing about which half of it.
    let onSelectDay: (Date) -> Void
    let onShiftChange: (Date, UUID, Date, Date) -> Void
    let onShiftAdd: (Date, Date, Date) -> Void
    let onShiftRemove: (Date, UUID) -> Void
    let onDelete: (Date) -> Void
    /// Opens the ranked list of past weeks (`WeekRankingView`).
    let onShowAllWeeks: () -> Void

    @State private var hoveringDay: Date?
    /// Which side the week being moved to slides in from; see `page(_:)`.
    @State private var insertionEdge: Edge = .trailing

    static let minimumHeight: CGFloat = 220
    /// Weekday and date, stacked above each column — two points taller
    /// than the text alone needs, for the capsule drawn round today's date.
    private static let labelHeight: CGFloat = 29
    /// The day's total — or, on a day with no hours on it yet, the hours
    /// being recommended for it.
    private static let totalHeight: CGFloat = 13
    /// The hover-revealed delete / reset row under each column.
    private static let columnControlsHeight: CGFloat = 12
    /// Gap between the pieces of a day's column.
    private static let columnStackSpacing: CGFloat = 2
    /// Gap between the week header and the columns beneath it.
    private static let headerGap: CGFloat = 4

    /// Everything in a column that isn't the bar: the labels above and
    /// below, the controls row, and the three gaps between the four of
    /// them. Counted in one place because the bar gets whatever is left,
    /// and an undercount here makes every column taller than the space it
    /// was given.
    private static var columnOverhead: CGFloat {
        labelHeight + totalHeight + columnControlsHeight
            + columnStackSpacing * 3
    }

    /// How far below the top of a column its bar begins — the y-axis labels
    /// drop by the same amount so they keep pointing at the right heights.
    private static var barTopInset: CGFloat {
        labelHeight + columnStackSpacing
    }
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
        // Overlaid rather than placed in the row, so the week's name stays
        // centred over the columns it names: a trailing button in the same
        // HStack would push it off centre by its own width.
        .overlay(alignment: .topTrailing) {
            Button(action: onShowAllWeeks) {
                Image(systemName: "list.number")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("All weeks, heaviest first")
            .accessibilityLabel("All weeks, heaviest first")
        }
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

        return Button {
            onSelectDay(day)
        } label: {
            VStack(spacing: 1) {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this day")
        // The capsule is colour alone, which VoiceOver doesn't see; the
        // date is read out either way, so this only has to add the word.
        // As the column's one focusable element it also has to say what
        // activating it does, which is the job the sun and moon used to do.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isToday
                ? "Today, \(Self.accessibilityDayFormatter.string(from: day))"
                : Self.accessibilityDayFormatter.string(from: day)
        )
        .accessibilityHint("Opens this day in the side panel")
    }

    /// What the day came to, under its bar: the date says which day this
    /// is, and this says what it amounted to — the two ends of the column.
    ///
    /// A day with no hours on it yet answers the same question in advance,
    /// with the hours being recommended for it ("7h?") or the amount it is
    /// already over by ("over 2h"). That figure used to float inside the
    /// bar, level with the first ghost, where it was a second place to look
    /// for a number the column already had a place for — and where it moved
    /// up and down with the recommendation instead of holding a line across
    /// the week.
    ///
    /// `recommendedHours` is nil at the weekend and on any day already
    /// worked, so the two cases can't both be true; the line is reserved on
    /// days with neither so what sits below it keeps a common baseline.
    private func columnTotal(day: Date, span: WorkdaySpan?) -> some View {
        let worked = (span?.shifts.isEmpty ?? true) ? nil : span?.roundedUpHours
        let recommended = worked == nil ? recommendedHours(day) : nil
        let isOverBudget = (recommended ?? 0) < 0

        return Group {
            if let worked {
                Text("\(worked)h")
                    .foregroundColor(DayFire.intensity(hours: worked, isWeekend: isWeekend(day)) > 0 ? .red : .secondary)
            } else if let recommended {
                Text(recommendationLabel(recommended))
                    .foregroundColor(isOverBudget ? .red : .secondary.opacity(0.6))
            } else {
                Text(" ")
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .fixedSize()
        .frame(height: Self.totalHeight)
    }

    /// The recommendation as it's written under a bar: the hours the day is
    /// being offered, or — once the week is spent — how far over it already
    /// is. The question mark is what keeps "7h?" from being read as a total
    /// the day has actually reached.
    private func recommendationLabel(_ recommendedHours: Double) -> String {
        if recommendedHours < 0 {
            return "over \(Int((-recommendedHours).rounded(.up)))h"
        }
        return "\(Int(recommendedHours.rounded(.up)))h?"
    }

    private static let accessibilityDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter
    }()

    private func dayColumns(chartHeight: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Self.columnSpacing) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                dayColumn(day: day, index: index, chartHeight: chartHeight)
            }
        }
    }

    /// One day's column, and a click anywhere in it opens that day in the
    /// side panel. A band behind the whole column marks the day the panel
    /// is showing — the whole column, because the column *is* the target
    /// now: there's no longer a sun and a moon to ring, and a day is opened
    /// by its header, its bar, or the space around them alike.
    private func dayColumn(day: Date, index: Int, chartHeight: CGFloat) -> some View {
        let span = spans[index]
        let isHovering = hoveringDay == day
        let isSelected = Calendar.current.isDate(selection.day, inSameDayAs: day)

        return VStack(spacing: Self.columnStackSpacing) {
            columnHeader(day: day)

            DayBar(
                span: span,
                day: day,
                chartHeight: chartHeight,
                isWeekend: isWeekend(day),
                barWidth: Self.barWidth,
                showsWorkdayTrack: true,
                recommendedHours: recommendedHours(day),
                shiftTemplates: shiftTemplates,
                meetings: meetings(day),
                onSelect: { onSelectDay(day) },
                onShiftChange: { shiftID, newStart, newEnd in
                    onShiftChange(day, shiftID, newStart, newEnd)
                },
                onShiftAdd: { newStart, newEnd in
                    onShiftAdd(day, newStart, newEnd)
                },
                onShiftRemove: { shiftID in
                    onShiftRemove(day, shiftID)
                },
                onDeleteDay: { onDelete(day) }
            )

            columnTotal(day: day, span: span)

            // Delete button, revealed on hover so the bar itself (only
            // ~10pt wide) doesn't need to host it.
            HStack(spacing: 8) {
                if !(span?.shifts.isEmpty ?? true) {
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
        // The bar has its own gesture and answers a press itself; this
        // catches the rest of the column — the header, the total, the space
        // around them — so the whole width of a day opens it.
        .onTapGesture { onSelectDay(day) }
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
