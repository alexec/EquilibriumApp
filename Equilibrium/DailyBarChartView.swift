import SwiftUI

/// Apple Health-style vertical bar chart: one pill-shaped bar per day from
/// start-of-work to end-of-work time, scaled from 6am to midnight. Day
/// columns stretch to fill the available width. Tapping a day opens an
/// edit popover for setting, overriding, or deleting its hours.
struct DailyBarChartView: View {
    let days: [Date]
    let spans: [WorkdaySpan?]
    let averageHours: (ArraySlice<Date>) -> Double
    let meetingPercentage: (ArraySlice<Date>) -> Double?
    let recommendedHours: (Date) -> Double?
    /// Rolling 8-week average hours per weekday; used to draw the baseline overlay.
    let rollingAverageHoursPerDay: Double
    let onSave: (Date, Date, Date, Int) -> Void
    let onClear: (Date) -> Void
    let onDelete: (Date) -> Void

    @State private var editingDay: Date?

    static let minimumHeight: CGFloat = 220
    private static let labelHeight: CGFloat = 44
    // Fits three stacked lines in the header: avg hours/day, meeting %, and
    // the late-nights/drift/weekend narrative.
    private static let weekHeaderHeight: CGFloat = 44
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

    /// Per-week narrative strings (late nights, drift, weekend work). Drift
    /// is measured relative to the preceding week's median start time.
    private var weekNarratives: [String?] {
        let allWeeks = weeks
        // Pre-compute each week's span slice and median in one pass so we
        // don't recompute the previous week's median on every iteration.
        let spansPerWeek = allWeeks.map { Array(weekSpans(for: $0)) }
        let mediansPerWeek = spansPerWeek.map { WeeklyInsights.medianStartHour(spans: $0) }
        return allWeeks.indices.map { i in
            WeeklyInsights.narrative(
                days: Array(allWeeks[i]),
                spans: spansPerWeek[i],
                previousMedianStart: i > 0 ? mediansPerWeek[i - 1] : nil
            )
        }
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
                ForEach(Array(weeks.enumerated()), id: \.offset) { i, week in
                    VStack(spacing: 1) {
                        Text("Avg \(Int(averageHours(week).rounded(.up)))h/day")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        if let pct = meetingPercentage(week) {
                            Text("\(Int(pct.rounded()))% meetings")
                                .font(.system(size: 9, weight: .regular))
                                .foregroundColor(.orange.opacity(0.9))
                        }
                        if let note = weekNarratives[i] {
                            Text(note)
                                .font(.system(size: 9, weight: .regular))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private func dayColumns(chartHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    dayColumn(day: day, index: index, chartHeight: chartHeight)
                }
            }
            if rollingAverageHoursPerDay > 0 {
                rollingAverageOverlay(chartHeight: chartHeight)
            }
        }
    }

    /// A dashed horizontal rule at the y-position that corresponds to
    /// working `rollingAverageHoursPerDay` hours starting at 9am.
    private func rollingAverageOverlay(chartHeight: CGFloat) -> some View {
        let endHour = (ChartScale.workdayStartHour + rollingAverageHoursPerDay)
            .clamped(to: ChartScale.startHour...ChartScale.endHour)
        let yOffset = CGFloat(ChartScale.fraction(of: endHour)) * chartHeight
        return GeometryReader { _ in
            Rectangle()
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundColor(Color.accentColor.opacity(0.65))
                .frame(height: 1.5)
                .offset(y: yOffset)
        }
        .allowsHitTesting(false)
    }

    private func dayColumn(day: Date, index: Int, chartHeight: CGFloat) -> some View {
        VStack(spacing: 2) {
            DayBar(
                span: spans[index],
                chartHeight: chartHeight,
                isWeekend: isWeekend(day),
                barWidth: Self.barWidth,
                showsWorkdayTrack: true,
                showsHoursLabel: true,
                recommendedHours: recommendedHours(day)
            )
            Text(weekdayLabel(day))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(dateLabel(day))
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { editingDay = day }
        .popover(isPresented: Binding(
            get: { editingDay == day },
            set: { if !$0 { editingDay = nil } }
        )) {
            EditHoursPopover(
                day: day,
                existingSpan: spans[index],
                onSave: { start, end, breakMinutes in
                    onSave(day, start, end, breakMinutes)
                    editingDay = nil
                },
                onRemoveOverride: {
                    onClear(day)
                    editingDay = nil
                },
                onDelete: {
                    onDelete(day)
                    editingDay = nil
                }
            )
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
