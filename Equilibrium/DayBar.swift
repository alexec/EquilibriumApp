import SwiftUI

/// A single day's vertical bar: renders actual worked hours when present,
/// otherwise a recommendation (or "over budget") placeholder.
struct DayBar: View {
    let span: WorkdaySpan?
    let chartHeight: CGFloat
    let isWeekend: Bool
    let barWidth: CGFloat
    let showsWorkdayTrack: Bool
    let showsHoursLabel: Bool
    let recommendedHours: Double?

    private var calendar: Calendar { .current }

    private func hourFraction(_ date: Date) -> Double {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60.0
    }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func hoursLabel(_ span: WorkdaySpan) -> String {
        "\(span.roundedUpHours)h"
    }

    private func recommendationLabel(_ recommendedHours: Double) -> String {
        if recommendedHours < 0 {
            return "over \(Int((-recommendedHours).rounded(.up)))h"
        }
        return "\(Int(recommendedHours.rounded(.up)))h?"
    }

    /// Whether to show the recommendation instead of the normal 9am-5pm
    /// workday track: only when there's no real data yet for this day.
    private var showsRecommendation: Bool {
        recommendedHours != nil && !(span.map { $0.hours > 0 } ?? false)
    }

    var body: some View {
        let workdayTop = CGFloat(ChartScale.fraction(of: ChartScale.workdayStartHour)) * chartHeight
        let isOverBudget = showsRecommendation && (recommendedHours ?? 0) < 0

        // The workday track normally spans 9am-5pm, but when there's no real
        // data yet and a recommendation exists, its height instead reflects
        // the recommended hours (anchored at 9am), so the recommendation and
        // "normal workday" indicator share one visual element. A negative
        // recommendation (already over budget) has no positive height to draw.
        let workdayHeight: CGFloat = {
            if showsRecommendation, let recommendedHours, recommendedHours > 0 {
                let recEndHour = (ChartScale.workdayStartHour + recommendedHours).clamped(to: ChartScale.startHour...ChartScale.endHour)
                return CGFloat(ChartScale.fraction(of: recEndHour) - ChartScale.fraction(of: ChartScale.workdayStartHour)) * chartHeight
            }
            return CGFloat(ChartScale.fraction(of: ChartScale.workdayEndHour) - ChartScale.fraction(of: ChartScale.workdayStartHour)) * chartHeight
        }()

        ZStack(alignment: .top) {
            Capsule()
                .fill(Color.gray.opacity(isWeekend ? 0.05 : 0.1))
                .frame(width: barWidth, height: chartHeight)

            if showsWorkdayTrack && !isWeekend {
                let recommendationIsZero = showsRecommendation && (recommendedHours ?? 0) == 0

                if !recommendationIsZero && !isOverBudget {
                    Capsule()
                        .fill(Color.gray.opacity(0.18))
                        .frame(width: barWidth, height: max(workdayHeight, barWidth))
                        .overlay(
                            Capsule()
                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                .foregroundColor(.secondary.opacity(0.6))
                                .frame(width: barWidth, height: max(workdayHeight, barWidth))
                        )
                        .offset(y: workdayTop)
                }

                if showsRecommendation, let recommendedHours, showsHoursLabel {
                    Text(recommendationLabel(recommendedHours))
                        .font(.system(size: 9, weight: isOverBudget ? .semibold : .regular))
                        .foregroundColor(isOverBudget ? .red : .secondary.opacity(0.6))
                        .fixedSize()
                        .offset(y: workdayTop - 13)
                }
            }

            if let span, span.hours > 0 {
                let startFrac = ChartScale.fraction(of: hourFraction(span.start))
                let endFrac = ChartScale.fraction(of: hourFraction(span.end))
                let topOffset = CGFloat(startFrac) * chartHeight
                let barHeight = CGFloat(max(endFrac - startFrac, 0)) * chartHeight
                let isOver = isWeekend || span.roundedUpHours > 8

                if let meetingFraction = span.meetingFraction, meetingFraction > 0 {
                    // Dual-tone: bottom portion = meetings (orange), rest = focus (gray/red)
                    let meetingHeight = barHeight * CGFloat(meetingFraction)
                    let focusHeight = max(barHeight - meetingHeight, 0)
                    let focusColor: Color = isOver ? .red : .gray
                    let meetingColor: Color = .orange

                    ZStack(alignment: .top) {
                        // Focus segment (top)
                        if focusHeight > 0 {
                            Capsule()
                                .fill(focusColor)
                                .frame(width: barWidth, height: max(focusHeight, barWidth / 2))
                        }
                        // Meeting segment (bottom), flush with the focus segment
                        let meetingOffset: CGFloat = focusHeight > 0 ? max(focusHeight, barWidth / 2) : 0
                        Capsule()
                            .fill(meetingColor)
                            .frame(width: barWidth, height: max(meetingHeight, barWidth / 2))
                            .offset(y: meetingOffset)
                    }
                    .frame(width: barWidth, height: max(barHeight, barWidth), alignment: .top)
                    .offset(y: topOffset)
                } else {
                    Capsule()
                        .fill(isOver ? Color.red : Color.gray)
                        .frame(width: barWidth, height: max(barHeight, barWidth))
                        .offset(y: topOffset)
                }

                if showsHoursLabel {
                    Text(hoursLabel(span))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isOver ? .red : .secondary)
                        .fixedSize()
                        .offset(y: topOffset - 13)
                }
            }
        }
        .frame(width: barWidth + (showsWorkdayTrack ? 10 : 4), height: chartHeight, alignment: .top)
        .contentShape(Rectangle())
        .help(helpText)
    }

    private var helpText: String {
        guard let span else { return "" }
        var parts = ["\(timeLabel(span.start)) – \(timeLabel(span.end))"]
        if let meetingMins = span.meetingMinutes {
            let meetingH = meetingMins / 60
            let meetingM = meetingMins % 60
            let focusMins = span.focusMinutes ?? 0
            let focusH = focusMins / 60
            let focusM = focusMins % 60
            parts.append("Meetings: \(meetingH)h \(meetingM)m · Focus: \(focusH)h \(focusM)m")
        }
        if let longestFocus = span.longestFocusBlockMinutes, longestFocus > 0 {
            let lh = longestFocus / 60
            let lm = longestFocus % 60
            parts.append("Longest focus block: \(lh > 0 ? "\(lh)h " : "")\(lm)m")
        }
        return parts.joined(separator: "\n")
    }
}
