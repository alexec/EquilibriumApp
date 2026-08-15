import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A single day's vertical bar: renders actual worked hours when present,
/// otherwise a recommendation (or "over budget") placeholder.
///
/// When calendar data (or a manual override) is available, the worked
/// portion of the bar splits into two drag-resizable segments — Focus
/// (blue, top) and Meeting (yellow, below it) — followed by a fixed Break
/// segment (gray, bottom): whatever part of the span isn't meeting time and
/// isn't focus time. Without calendar data there's just Focus/Break.
struct DayBar: View {
    let span: WorkdaySpan?
    let chartHeight: CGFloat
    let isWeekend: Bool
    let barWidth: CGFloat
    let showsWorkdayTrack: Bool
    let showsHoursLabel: Bool
    let recommendedHours: Double?
    /// Called with the new meeting-minute value while the focus/meeting
    /// boundary is being dragged, and again with the final value on release.
    var onMeetingSplitChange: (Int) -> Void = { _ in }

    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging = false
    @State private var isPulsingHigh = false

    private static let focusColor = Color.blue
    private static let meetingColor = Color.yellow
    private static let breakColor = Color.gray.opacity(0.55)

    private var calendar: Calendar { .current }

    private func hourFraction(_ date: Date) -> Double {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60.0
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
                daySegments(span: span)

                if showsHoursLabel {
                    let startFrac = ChartScale.fraction(of: hourFraction(span.start))
                    let topOffset = CGFloat(startFrac) * chartHeight
                    let isOver = span.roundedUpHours > 8
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
    }

    /// The stacked Focus/Meeting/Break capsules for a day with real hours,
    /// plus the drag handle on the Focus/Meeting boundary when a split
    /// (calendar-derived or manually overridden) is available to adjust.
    @ViewBuilder
    private func daySegments(span: WorkdaySpan) -> some View {
        let startFrac = ChartScale.fraction(of: hourFraction(span.start))
        let endFrac = ChartScale.fraction(of: hourFraction(span.end))
        let topOffset = CGFloat(startFrac) * chartHeight
        let barHeight = CGFloat(max(endFrac - startFrac, 0)) * chartHeight

        // Worked portion (focus + meeting) vs. break, in points.
        let workedFraction = span.hours > 0 ? CGFloat(span.effectiveHours / span.hours) : 0
        let workedHeight = barHeight * workedFraction
        let breakHeight = max(barHeight - workedHeight, 0)

        // Live-dragged meeting height, clamped within the worked region.
        let baseMeetingFraction = CGFloat(span.meetingFraction ?? 0)
        let baseMeetingHeight = workedHeight * baseMeetingFraction
        let meetingHeight: CGFloat = {
            guard span.meetingFraction != nil else { return 0 }
            let raw = isDragging ? (baseMeetingHeight - dragTranslation) : baseMeetingHeight
            return min(max(raw, 0), workedHeight)
        }()
        let focusHeight = max(workedHeight - meetingHeight, 0)

        let isOver8h = span.roundedUpHours > 8

        ZStack(alignment: .top) {
            if focusHeight > 0 {
                Capsule()
                    .fill(Self.focusColor)
                    .frame(width: barWidth, height: max(focusHeight, barWidth / 2))
            }
            if meetingHeight > 0 {
                Capsule()
                    .fill(Self.meetingColor)
                    .frame(width: barWidth, height: max(meetingHeight, barWidth / 2))
                    .offset(y: focusHeight)
            }
            if breakHeight > 0 {
                Capsule()
                    .fill(Self.breakColor)
                    .frame(width: barWidth, height: max(breakHeight, barWidth / 2))
                    .offset(y: focusHeight + meetingHeight)
            }
        }
        .frame(width: barWidth, height: max(barHeight, barWidth), alignment: .top)
        // A slowly pulsing red outline around the whole stack signals >8h
        // without giving up the segment fill colors to a 4th "over budget"
        // color. Pulsing (vs. a static outline) reads more clearly as "this
        // needs attention" rather than just another fixed color in the mix.
        .overlay(
            Group {
                if isOver8h {
                    Capsule()
                        .stroke(Color.red, lineWidth: 1.5)
                        .frame(width: barWidth, height: max(barHeight, barWidth))
                        .opacity(isPulsingHigh ? 1.0 : 0.25)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                                isPulsingHigh = true
                            }
                        }
                }
            }
        )
        .overlay(
            // Invisible, wide drag surface covering the whole bar — not just
            // a thin strip on the boundary — so a drag started anywhere on
            // the visible capsules is captured by this gesture rather than
            // falling through to the window's isMovableByWindowBackground,
            // which otherwise wins the mouseDown and drags the whole window.
            // minimumDistance: 0 claims the touch immediately for the same
            // reason: any delay lets the window-drag get there first.
            Group {
                if span.meetingFraction != nil, workedHeight > 0 {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: barWidth + 20, height: max(barHeight, barWidth))
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    isDragging = true
                                    dragTranslation = value.translation.height
                                }
                                .onEnded { value in
                                    let effectiveMinutes = Int(span.effectiveHours * 60.0)
                                    let finalMeetingHeight = min(max(baseMeetingHeight - value.translation.height, 0), workedHeight)
                                    let finalFraction = workedHeight > 0 ? Double(finalMeetingHeight / workedHeight) : 0
                                    // Snap to the nearest 5 minutes.
                                    let rawMinutes = Int((finalFraction * Double(effectiveMinutes)).rounded())
                                    let snapped = (rawMinutes / 5) * 5
                                    isDragging = false
                                    dragTranslation = 0
                                    onMeetingSplitChange(snapped)
                                }
                        )
                        #if os(macOS)
                        .onHover { hovering in
                            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                        }
                        #endif
                }
            }
        )
        .offset(y: topOffset)
    }
}
