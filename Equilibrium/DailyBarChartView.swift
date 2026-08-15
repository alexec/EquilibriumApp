import SwiftUI

/// Apple Health-style vertical bar chart: one pill-shaped bar per day from
/// start-of-work to end-of-work time, scaled from 6am to midnight. Day
/// columns stretch to fill the available width. Drag the boundary between
/// a bar's focus (blue) and meeting (yellow) segments to adjust the split;
/// hover a day to reveal Delete / Reset-split buttons.
struct DailyBarChartView: View {
    let days: [Date]
    let spans: [WorkdaySpan?]
    let recommendedHours: (Date) -> Double?
    /// LLM-generated "You worked ..." caption for the week starting on the
    /// given date, or nil if unavailable/not generated yet — in which case
    /// the deterministic `WeekHeaderStats.fallbackSentence` is shown instead.
    let aiWeekSummary: (Date) -> String?
    let onMeetingSplitChange: (Date, Int) -> Void
    let onResetMeetingSplit: (Date) -> Void
    let onDelete: (Date) -> Void

    @State private var hoveringDay: Date?

    static let minimumHeight: CGFloat = 220
    private static let labelHeight: CGFloat = 44
    // Fits the per-week stats sentence, which can wrap to two lines.
    private static let weekHeaderHeight: CGFloat = 32
    private static let yAxisWidth: CGFloat = 36
    private static let yAxisHours: [Double] = [6, 9, 12, 15, 18, 21]
    private static let barWidth: CGFloat = 10
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

    /// Splits `days` into 7-day weeks for the per-week average header.
    private var weeks: [ArraySlice<Date>] {
        stride(from: 0, to: days.count, by: 7).map { days[$0..<min($0 + 7, days.count)] }
    }

    /// Returns the span slice that corresponds to a given week slice of `days`.
    private func weekSpans(for week: ArraySlice<Date>) -> ArraySlice<WorkdaySpan?> {
        let start = week.startIndex
        let end = min(start + week.count, spans.count)
        guard start < spans.count else { return spans[spans.endIndex..<spans.endIndex] }
        return spans[start..<end]
    }

    /// The header line for a week: the LLM-generated caption when one's
    /// available, else the deterministic "Nh meetings/day, ..." sentence
    /// built from the same `WeekHeaderStats`. Nil when the week has no
    /// data at all yet.
    private func weekHeaderLine(weekStart: Date, spans: [WorkdaySpan?]) -> String? {
        guard let stats = WeeklyInsightGenerator.WeekHeaderStats.compute(from: spans) else { return nil }
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
                }
            }
        }
        .frame(minHeight: Self.minimumHeight)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var weekAverageHeader: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: Self.yAxisWidth)
            HStack(spacing: Self.columnSpacing) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    if let weekStart = week.first,
                       let line = weekHeaderLine(weekStart: weekStart, spans: Array(weekSpans(for: week))) {
                        Text(line)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
            }
        }
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
                chartHeight: chartHeight,
                isWeekend: isWeekend(day),
                barWidth: Self.barWidth,
                showsWorkdayTrack: true,
                showsHoursLabel: true,
                recommendedHours: recommendedHours(day),
                onMeetingSplitChange: { minutes in onMeetingSplitChange(day, minutes) }
            )
            Text(weekdayLabel(day))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(dateLabel(day))
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(.secondary.opacity(0.7))

            // Delete / Reset-split buttons, revealed on hover so the bar
            // itself (only ~10pt wide) doesn't need to host them.
            HStack(spacing: 8) {
                if span?.manualMeetingMinutes != nil {
                    Button {
                        onResetMeetingSplit(day)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .help("Reset meeting/focus split to calendar data")
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
