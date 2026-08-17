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
    let onMeetingChange: (Date, UUID, Date, Date) -> Void
    let onWorkdayChange: (Date, Date, Date) -> Void
    let onResetMeetings: (Date) -> Void
    let onDelete: (Date) -> Void

    @State private var hoveringDay: Date?
    /// Which side the week being moved to slides in from; see `page(_:)`.
    @State private var insertionEdge: Edge = .trailing

    static let minimumHeight: CGFloat = 220
    private static let labelHeight: CGFloat = 44
    // Fits the week navigation row plus the stats sentence below it, which
    // can still wrap to two lines at the narrowest window width.
    private static let weekHeaderHeight: CGFloat = 46
    private static let yAxisWidth: CGFloat = 36
    private static let yAxisHours: [Double] = [6, 9, 12, 15, 18, 21]
    // Seven columns rather than fourteen: at the 380pt minimum window width
    // a column is ~34pt, so an 18pt bar plus its 10pt workday track still
    // clears its neighbours.
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
            let chartHeight = geo.size.height - Self.labelHeight - Self.weekHeaderHeight

            VStack(alignment: .leading, spacing: 4) {
                weekAverageHeader

                HStack(alignment: .top, spacing: 6) {
                    YAxisView(
                        hours: Self.yAxisHours,
                        chartHeight: chartHeight,
                        width: Self.yAxisWidth,
                        label: yAxisLabel
                    )

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
                weekStepButton("chevron.left", enabled: canShowPreviousWeek) { page(.previous) }
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Previous week (⌘[)")
                Text(weekLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 96)
                weekStepButton("chevron.right", enabled: canShowNextWeek) { page(.next) }
                    .keyboardShortcut("]", modifiers: .command)
                    .help("Next week (⌘])")
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

    private func weekStepButton(_ systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
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
    }

    private func dayColumns(chartHeight: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Self.columnSpacing) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                dayColumn(day: day, index: index, chartHeight: chartHeight)
            }
        }
    }

    private func dayColumn(day: Date, index: Int, chartHeight: CGFloat) -> some View {
        let span = spans[index]
        let isHovering = hoveringDay == day

        return VStack(spacing: 2) {
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
            Text(weekdayLabel(day))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(dateLabel(day))
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(.secondary.opacity(0.7))

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
