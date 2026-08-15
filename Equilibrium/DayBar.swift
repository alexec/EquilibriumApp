import SwiftUI
#if os(macOS)
import AppKit

/// An invisible NSView whose only job is telling AppKit not to treat a
/// click here as "drag the window." SwiftUI gesture-priority tricks
/// (`.highPriorityGesture`, `minimumDistance: 0`) weren't reliable against
/// `window.isMovableByWindowBackground` (set in `WindowChromeRemover`,
/// since the window has no title bar) — it kept winning the mouseDown race
/// and dragging the whole window instead of resizing a capsule. This is
/// the actual AppKit-level override: `mouseDownCanMoveWindow` is what
/// `isMovableByWindowBackground` consults per-view before starting a
/// window drag, so returning `false` here takes precedence over it,
/// regardless of what SwiftUI's gesture recognizers are doing.
private struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BlockerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
#endif

/// A single day's vertical bar: renders actual worked hours when present,
/// otherwise a recommendation (or "over budget") placeholder.
///
/// The bar itself is a plain "work" capsule (gray) from start to end, with
/// a "break" capsule (lighter gray) beneath it sized by the auto-detected
/// break — the only two things we don't have precise times for. Meetings
/// (real calendar times) are drawn as separate yellow blocks positioned at
/// their actual times, each individually drag-resizable/movable — see
/// `MeetingBlockView`. There's no "focus" segment: it was always a derived
/// guess (effective hours minus meetings), never a directly known quantity.
struct DayBar: View {
    let span: WorkdaySpan?
    let chartHeight: CGFloat
    let isWeekend: Bool
    let barWidth: CGFloat
    let showsWorkdayTrack: Bool
    let showsHoursLabel: Bool
    let recommendedHours: Double?
    /// The configured workday span (from `WorkPreferences`), used to
    /// position the dashed "normal workday" track.
    let workdayStartHour: Double
    let workdayEndHour: Double
    /// Called with a meeting's id and its new (start, end) once a drag
    /// (resize-top, resize-bottom, or move) ends.
    var onMeetingChange: (UUID, Date, Date) -> Void = { _, _, _ in }

    private static let workColor = Color.gray
    private static let breakColor = Color.gray.opacity(0.35)

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
        let workdayTop = CGFloat(ChartScale.fraction(of: workdayStartHour)) * chartHeight
        let isOverBudget = showsRecommendation && (recommendedHours ?? 0) < 0

        // The workday track normally spans the configured workday, but when
        // there's no real data yet and a recommendation exists, its height
        // instead reflects the recommended hours (anchored at the
        // configured start), so the recommendation and "normal workday"
        // indicator share one visual element. A negative recommendation
        // (already over budget) has no positive height to draw.
        let workdayHeight: CGFloat = {
            if showsRecommendation, let recommendedHours, recommendedHours > 0 {
                let recEndHour = (workdayStartHour + recommendedHours).clamped(to: ChartScale.startHour...ChartScale.endHour)
                return CGFloat(ChartScale.fraction(of: recEndHour) - ChartScale.fraction(of: workdayStartHour)) * chartHeight
            }
            return CGFloat(ChartScale.fraction(of: workdayEndHour) - ChartScale.fraction(of: workdayStartHour)) * chartHeight
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

                ForEach(span.meetings) { meeting in
                    MeetingBlockView(
                        meeting: meeting,
                        chartHeight: chartHeight,
                        barWidth: barWidth,
                        dayStart: span.start,
                        dayEnd: span.end,
                        onChange: { newStart, newEnd in
                            onMeetingChange(meeting.id, newStart, newEnd)
                        }
                    )
                }

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

    /// The "work" and "break" capsules for a day with real hours — the
    /// only two things drawn proportionally rather than at a real time,
    /// since intra-day break gaps are only known as a total duration, not
    /// exactly when they happened.
    private func daySegments(span: WorkdaySpan) -> some View {
        let startFrac = ChartScale.fraction(of: hourFraction(span.start))
        let endFrac = ChartScale.fraction(of: hourFraction(span.end))
        let topOffset = CGFloat(startFrac) * chartHeight
        let barHeight = CGFloat(max(endFrac - startFrac, 0)) * chartHeight

        let workedFraction = span.hours > 0 ? CGFloat(span.effectiveHours / span.hours) : 0
        let workedHeight = barHeight * workedFraction
        let breakHeight = max(barHeight - workedHeight, 0)

        return ZStack(alignment: .top) {
            if workedHeight > 0 {
                Capsule()
                    .fill(Self.workColor)
                    .frame(width: barWidth, height: max(workedHeight, barWidth / 2))
            }
            if breakHeight > 0 {
                Capsule()
                    .fill(Self.breakColor)
                    .frame(width: barWidth, height: max(breakHeight, barWidth / 2))
                    .offset(y: workedHeight)
            }
        }
        .frame(width: barWidth, height: max(barHeight, barWidth), alignment: .top)
        .offset(y: topOffset)
    }
}

/// A single meeting, drawn at its real start/end time and drag-editable
/// three ways, like an event in a calendar day view: drag the top edge to
/// move `start`, the bottom edge to move `end`, or the middle to move the
/// whole block (preserving its duration). Too-short blocks (under ~16pt)
/// skip the edge handles and are move-only, since there's no room to grab
/// a distinct top/bottom strip.
private struct MeetingBlockView: View {
    let meeting: MeetingBlock
    let chartHeight: CGFloat
    let barWidth: CGFloat
    let dayStart: Date
    let dayEnd: Date
    let onChange: (Date, Date) -> Void

    private enum DragMode {
        case moveWhole, resizeTop, resizeBottom
    }

    @State private var dragMode: DragMode?
    @State private var dragPointsDelta: CGFloat = 0

    private static let edgeHandleHeight: CGFloat = 6
    private static let splitThreshold: CGFloat = 16
    private static let minBlockHeight: CGFloat = 6

    private var secondsPerPoint: Double {
        ChartScale.secondsPerPoint(chartHeight: chartHeight)
    }

    private var displayedStart: Date {
        guard dragMode == .resizeTop || dragMode == .moveWhole else { return meeting.start }
        let candidate = meeting.start.addingTimeInterval(Double(dragPointsDelta) * secondsPerPoint)
        return min(max(candidate, dayStart), dayEnd)
    }

    private var displayedEnd: Date {
        guard dragMode == .resizeBottom || dragMode == .moveWhole else { return meeting.end }
        let candidate = meeting.end.addingTimeInterval(Double(dragPointsDelta) * secondsPerPoint)
        return min(max(candidate, dayStart), dayEnd)
    }

    var body: some View {
        let topOffset = CGFloat(ChartScale.fraction(of: displayedStart)) * chartHeight
        let bottomOffset = CGFloat(ChartScale.fraction(of: displayedEnd)) * chartHeight
        let height = max(bottomOffset - topOffset, Self.minBlockHeight)
        let canSplitHandles = height >= Self.splitThreshold

        ZStack(alignment: .top) {
            Capsule()
                .fill(Color.yellow)
                .frame(width: barWidth, height: height)

            if canSplitHandles {
                dragHandle(mode: .resizeTop, height: Self.edgeHandleHeight)
                dragHandle(mode: .moveWhole, height: height - 2 * Self.edgeHandleHeight)
                    .offset(y: Self.edgeHandleHeight)
                dragHandle(mode: .resizeBottom, height: Self.edgeHandleHeight)
                    .offset(y: height - Self.edgeHandleHeight)
            } else {
                dragHandle(mode: .moveWhole, height: height)
            }
        }
        .frame(width: barWidth, height: height, alignment: .top)
        .offset(y: topOffset)
    }

    private func dragHandle(mode: DragMode, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: barWidth + 20, height: max(height, 1))
            .contentShape(Rectangle())
            #if os(macOS)
            .background(WindowDragBlocker())
            #endif
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragMode = mode
                        dragPointsDelta = value.translation.height
                    }
                    .onEnded { value in
                        let delta = Double(value.translation.height) * secondsPerPoint
                        var finalStart = meeting.start
                        var finalEnd = meeting.end
                        switch mode {
                        case .moveWhole:
                            finalStart = meeting.start.addingTimeInterval(delta)
                            finalEnd = meeting.end.addingTimeInterval(delta)
                        case .resizeTop:
                            finalStart = meeting.start.addingTimeInterval(delta)
                        case .resizeBottom:
                            finalEnd = meeting.end.addingTimeInterval(delta)
                        }
                        finalStart = min(max(finalStart, dayStart), dayEnd)
                        finalEnd = min(max(finalEnd, dayStart), dayEnd)

                        dragMode = nil
                        dragPointsDelta = 0

                        let snappedStart = snap(finalStart)
                        let snappedEnd = snap(finalEnd)
                        if snappedStart < snappedEnd {
                            onChange(snappedStart, snappedEnd)
                        }
                    }
            )
            #if os(macOS)
            .onHover { hovering in
                if hovering {
                    (mode == .moveWhole ? NSCursor.openHand : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
    }

    /// Rounds to the nearest 5 minutes.
    private func snap(_ date: Date) -> Date {
        let interval: TimeInterval = 5 * 60
        let rounded = (date.timeIntervalSinceReferenceDate / interval).rounded() * interval
        return Date(timeIntervalSinceReferenceDate: rounded)
    }
}
