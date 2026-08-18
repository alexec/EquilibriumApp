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
/// otherwise a recommendation (or "over budget") placeholder — or, for a
/// day with no data at all yet, an empty column whose dashed track you can
/// click to accept, or drag on to draw a custom span (see `WorkdayBlockView`).
///
/// The workday itself (Work capsule + Break capsule beneath it, sized by
/// the auto-detected break — the one thing here without a precise time) is
/// drag-editable the same three ways as a meeting: top edge = start,
/// bottom edge = end, middle = move. Meetings (real calendar times) are
/// drawn as separate meeting blocks on top (yellow normally; a lighter
/// red on fiery days so they stay compatible with the work capsule),
/// positioned at their actual times, each independently drag-editable —
/// see `MeetingBlockView`. There's no "focus" segment: it was always a
/// derived guess (effective hours minus meetings), never a directly known
/// quantity.
struct DayBar: View {
    let span: WorkdaySpan?
    /// The calendar day this bar represents — needed to construct a
    /// brand-new span (with real dates, not just hour-of-day) when the
    /// user draws one on a day with no data yet.
    let day: Date
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
    /// Called with the day's new (start, end) once a drag on the workday
    /// itself ends — whether resizing/moving an existing day or drawing a
    /// brand new one from scratch.
    var onWorkdayChange: (Date, Date) -> Void = { _, _ in }

    private var calendar: Calendar { .current }

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

    /// The dashed track's start/end hours when this day is empty and a
    /// track is visible — what a click on that capsule should create.
    /// Nil when there's already real data, weekends, or no positive
    /// height to accept (over budget / zero recommendation).
    private var suggestedTrackHours: (start: Double, end: Double)? {
        guard !(span.map { $0.hours > 0 } ?? false) else { return nil }
        guard showsWorkdayTrack && !isWeekend else { return nil }
        if showsRecommendation, let recommendedHours {
            guard recommendedHours > 0 else { return nil }
            let end = (workdayStartHour + recommendedHours)
                .clamped(to: ChartScale.startHour...ChartScale.endHour)
            return (workdayStartHour, end)
        }
        return (workdayStartHour, workdayEndHour)
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

            WorkdayBlockView(
                span: span,
                day: day,
                chartHeight: chartHeight,
                barWidth: barWidth,
                isWeekend: isWeekend,
                // Match the dashed track the user sees: recommended hours when
                // one exists, otherwise the configured workday. A click on that
                // empty capsule places a real span there (see emptyDayView).
                suggestedStartHour: suggestedTrackHours?.start,
                suggestedEndHour: suggestedTrackHours?.end,
                onChange: onWorkdayChange
            )

            // Meetings render even on days with no work capsule yet (future
            // week days get a 0h span that only holds calendar blocks).
            if let span, !span.meetings.isEmpty {
                let (clampStart, clampEnd) = meetingClampBounds(for: span, day: day)
                let fireIntensity = DayFire.intensity(hours: span.roundedUpHours, isWeekend: isWeekend)
                ForEach(span.meetings) { meeting in
                    MeetingBlockView(
                        meeting: meeting,
                        chartHeight: chartHeight,
                        barWidth: barWidth,
                        dayStart: clampStart,
                        dayEnd: clampEnd,
                        color: DayFire.meetingColor(intensity: fireIntensity),
                        onChange: { newStart, newEnd in
                            onMeetingChange(meeting.id, newStart, newEnd)
                        }
                    )
                }
            }

        }
        .frame(width: barWidth + (showsWorkdayTrack ? 10 : 4), height: chartHeight, alignment: .top)
        .contentShape(Rectangle())
    }

    /// Drag bounds for meetings: the workday when present, otherwise the
    /// chart's 6am–midnight window so future-day meetings stay editable.
    private func meetingClampBounds(for span: WorkdaySpan, day: Date) -> (Date, Date) {
        if span.hours > 0 {
            return (span.start, span.end)
        }
        let startOfDay = calendar.startOfDay(for: day)
        let start = calendar.date(
            bySettingHour: Int(ChartScale.startHour), minute: 0, second: 0, of: startOfDay
        ) ?? startOfDay
        let end = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        return (start, end)
    }
}

/// A single meeting, drawn at its real start/end time and drag-editable
/// like an event in a calendar day view. Blocks longer than 2h support
/// three-way edit (top = start, bottom = end, middle = move). Short
/// blocks (≤2h) are resize-only — top half moves `start`, bottom half
/// moves `end` — since there's no room for a distinct move strip.
private struct MeetingBlockView: View {
    let meeting: MeetingBlock
    let chartHeight: CGFloat
    let barWidth: CGFloat
    let dayStart: Date
    let dayEnd: Date
    let color: Color
    let onChange: (Date, Date) -> Void

    private enum DragMode {
        case moveWhole, resizeTop, resizeBottom
    }

    @State private var dragMode: DragMode?
    @State private var dragPointsDelta: CGFloat = 0

    private static let edgeHandleHeight: CGFloat = 6
    private static let minBlockHeight: CGFloat = 6
    /// Meetings at or under this duration skip the middle move handle and
    /// split the whole block into top/bottom resize halves.
    private static let resizeOnlyMaxHours: Double = 2

    private var secondsPerPoint: Double {
        ChartScale.secondsPerPoint(chartHeight: chartHeight)
    }

    private var isResizeOnly: Bool {
        meeting.end.timeIntervalSince(meeting.start) <= Self.resizeOnlyMaxHours * 3600
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

        ZStack(alignment: .top) {
            Capsule()
                .fill(color)
                .frame(width: barWidth, height: height)

            if isResizeOnly {
                let half = height / 2
                dragHandle(mode: .resizeTop, height: half)
                dragHandle(mode: .resizeBottom, height: half)
                    .offset(y: half)
            } else {
                dragHandle(mode: .resizeTop, height: Self.edgeHandleHeight)
                dragHandle(mode: .moveWhole, height: height - 2 * Self.edgeHandleHeight)
                    .offset(y: Self.edgeHandleHeight)
                dragHandle(mode: .resizeBottom, height: Self.edgeHandleHeight)
                    .offset(y: height - Self.edgeHandleHeight)
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

/// Heat for a "fiery" day — shades of red once you're over the balanced
/// 8h line (or working a weekend). 0 = calm gray; 1 = full red.
///
/// Not private: the chart's per-day hours label is coloured by the same
/// rule as the capsule it describes, so the two agree about which days
/// count as fiery.
enum DayFire {
    static let balancedHours = 8

    /// 0 under the line; ramps 9→0.25 … 12+→1. Any weekend work is full fire.
    static func intensity(hours: Int, isWeekend: Bool) -> Double {
        if isWeekend, hours > 0 { return 1 }
        guard hours > balancedHours else { return 0 }
        return min(Double(hours - balancedHours) / 4.0, 1.0)
    }

    /// Work capsule: gray at 0, soft orange-red → deep red as intensity climbs.
    static func workColor(intensity: Double) -> Color {
        guard intensity > 0 else { return .gray }
        let green = 0.42 - intensity * 0.32
        let blue = 0.22 - intensity * 0.14
        return Color(red: 0.90, green: green, blue: blue)
    }

    /// Break capsule: a lighter shade of the same fire.
    static func breakColor(intensity: Double) -> Color {
        guard intensity > 0 else { return Color.gray.opacity(0.35) }
        return workColor(intensity: intensity).opacity(0.40)
    }

    /// Meeting overlay: yellow on calm days; a brighter coral-red on fiery
    /// days so blocks stay distinct from the work capsule without clashing.
    static func meetingColor(intensity: Double) -> Color {
        guard intensity > 0 else { return .yellow }
        let green = 0.52 - intensity * 0.22
        let blue = 0.30 - intensity * 0.12
        return Color(red: 1.0, green: green, blue: blue)
    }
}

/// The workday itself: Work + Break capsules for a day that already has
/// data, drag-editable the same three ways as a meeting block (top edge =
/// start, bottom edge = end, middle = move); or, for a day with no data at
/// all yet, click the dashed track to accept those hours, or click-and-drag
/// anywhere in the column to draw a brand-new span from scratch — like
/// dragging out a new event in a calendar day view (order-independent:
/// drag up or down, whichever end you started from).
private struct WorkdayBlockView: View {
    let span: WorkdaySpan?
    let day: Date
    let chartHeight: CGFloat
    let barWidth: CGFloat
    let isWeekend: Bool
    /// Hours matching the visible dashed track; a tap inside that region
    /// creates a span at these times instead of requiring a draw-drag.
    let suggestedStartHour: Double?
    let suggestedEndHour: Double?
    let onChange: (Date, Date) -> Void

    private enum DragMode {
        case moveWhole, resizeTop, resizeBottom
    }

    @State private var dragMode: DragMode?
    @State private var dragPointsDelta: CGFloat = 0

    @State private var drawStartY: CGFloat?
    @State private var drawCurrentY: CGFloat?

    /// Grab zones at each end of the capsule. Proportional so a short day
    /// stays resizable — a fixed 8pt handle vanished entirely on bars under
    /// ~80 minutes, leaving them movable but not adjustable — and bounded so
    /// a long one still has a middle to grab.
    private static let minHandleHeight: CGFloat = 6
    private static let maxHandleHeight: CGFloat = 14
    /// How far outside the capsule still counts as grabbing it. Generous
    /// vertically because there's nothing above or below to compete with —
    /// and because a press a couple of points past the end of a pill is
    /// plainly aimed at that pill.
    private static let grabPadding: CGFloat = 8
    /// A drag can't shrink a day below this.
    private static let minimumDuration: TimeInterval = 15 * 60
    /// Below this a press is a click, not a drag, and changes nothing.
    private static let dragSlop: CGFloat = 2
    /// Movement below this (in points) counts as a click, not a draw.
    private static let tapSlop: CGFloat = 4
    private static let drawColor = Color.gray.opacity(0.5)

    private var secondsPerPoint: Double {
        ChartScale.secondsPerPoint(chartHeight: chartHeight)
    }

    var body: some View {
        if let span, span.hours > 0 {
            existingSpanView(span: span)
        } else {
            emptyDayView()
        }
    }

    // MARK: - Existing span: three-way edit

    /// The capsule, plus one gesture covering the whole column.
    ///
    /// The gesture deliberately lives on this stationary container rather
    /// than on the capsule: a `DragGesture` measures translation inside its
    /// own view, and the capsule moves as a *result* of the drag, so
    /// attaching it there measured each frame's movement from an origin
    /// that had just shifted — the capsule lagged, then caught up, and
    /// tracked the pointer unevenly. Nothing here moves while you drag, so
    /// the numbers stay honest.
    @ViewBuilder
    private func existingSpanView(span: WorkdaySpan) -> some View {
        let (liveStart, liveEnd) = previewTimes(span: span)

        let topOffset = CGFloat(ChartScale.fraction(of: liveStart)) * chartHeight
        let bottomOffset = CGFloat(ChartScale.fraction(of: liveEnd)) * chartHeight
        let barHeight = max(bottomOffset - topOffset, 0)

        // Break height comes from the live duration, not the saved one:
        // sized from the stored total, the split slid around inside the
        // capsule as the capsule itself was resized.
        let liveHours = liveEnd.timeIntervalSince(liveStart) / 3600
        let breakHours = Double(span.breakMinutesUsed) / 60
        let workedFraction = liveHours > 0 ? CGFloat(max(liveHours - breakHours, 0) / liveHours) : 0
        let workedHeight = barHeight * workedFraction
        let breakHeight = max(barHeight - workedHeight, 0)

        // Heat from the live hours too, for the same reason: taken from the
        // saved value, the capsule stayed calm all the way through a drag
        // over the 8h line and only turned red once you let go.
        let liveWorkedHours = Int(max(liveHours - breakHours, 0).rounded(.up))
        let fire = DayFire.intensity(hours: liveWorkedHours, isWeekend: isWeekend)
        let workColor = DayFire.workColor(intensity: fire)
        let breakColor = DayFire.breakColor(intensity: fire)

        ZStack(alignment: .top) {
            if workedHeight > 0 {
                Capsule()
                    .fill(workColor)
                    .frame(width: barWidth, height: max(workedHeight, barWidth / 2))
                    .offset(y: topOffset)
            }
            if breakHeight > 0 {
                Capsule()
                    .fill(breakColor)
                    .frame(width: barWidth, height: max(breakHeight, barWidth / 2))
                    .offset(y: topOffset + workedHeight)
            }
        }
        // Fills the width `DayBar` gives it rather than claiming a fixed
        // margin of its own: at 20pt either side the grab area overhung the
        // column into its neighbours, where a press near the boundary could
        // start a drag on the wrong day.
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: chartHeight, alignment: .top)
        .contentShape(Rectangle())
        #if os(macOS)
        .background(WindowDragBlocker())
        #endif
        .gesture(
            DragGesture(minimumDistance: Self.dragSlop)
                .onChanged { value in
                    if dragMode == nil {
                        dragMode = mode(forStartY: value.startLocation.y, span: span)
                    }
                    guard dragMode != nil else { return }
                    dragPointsDelta = value.translation.height
                }
                .onEnded { value in
                    defer {
                        dragMode = nil
                        dragPointsDelta = 0
                    }
                    guard let mode = dragMode else { return }
                    let (start, end) = times(span: span, mode: mode, deltaPoints: value.translation.height)
                    onChange(start, end)
                }
        )
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                switch mode(forStartY: point.y, span: span) {
                case .resizeTop, .resizeBottom: NSCursor.resizeUpDown.set()
                case .moveWhole: NSCursor.openHand.set()
                case nil: NSCursor.arrow.set()
                }
            case .ended:
                NSCursor.arrow.set()
            }
        }
        #endif
    }

    /// Which part of the capsule a press at `y` has hold of, or nil for a
    /// press that missed it.
    private func mode(forStartY y: CGFloat, span: WorkdaySpan) -> DragMode? {
        let top = CGFloat(ChartScale.fraction(of: span.start)) * chartHeight
        // The drawn capsule keeps a minimum height however short the day is,
        // so a quarter-hour is visibly ~18pt of pill sitting below where its
        // end time falls. Hit-testing against the end time would call the
        // lower half of that pill a miss — exactly the short days that are
        // hardest to grab in the first place.
        let height = max(CGFloat(ChartScale.fraction(of: span.end)) * chartHeight - top, barWidth)
        let bottom = top + height
        let handle = min(Self.maxHandleHeight, max(Self.minHandleHeight, height / 3))

        guard y >= top - Self.grabPadding, y <= bottom + Self.grabPadding else { return nil }
        if y <= top + handle { return .resizeTop }
        if y >= bottom - handle { return .resizeBottom }
        return .moveWhole
    }

    /// What the capsule currently shows: the saved times, or the result of
    /// the drag in progress.
    private func previewTimes(span: WorkdaySpan) -> (Date, Date) {
        guard let dragMode else { return (span.start, span.end) }
        return times(span: span, mode: dragMode, deltaPoints: dragPointsDelta)
    }

    /// The one place a drag turns into times — used for both the live
    /// capsule and the value saved on release, so what you let go of is
    /// exactly what you get. Snapping and clamping happen here rather than
    /// on release, which is what stopped the capsule jumping at the end of
    /// every drag.
    ///
    /// Rounding is applied to what the drag actually moves, and nothing
    /// else. Resizing snaps the edge you have hold of and leaves the far
    /// one exactly as it was; moving snaps the start and carries the
    /// original duration with it, so both ends shift together and the day
    /// keeps its length.
    ///
    /// What that avoids is rounding a time nobody touched: these come from
    /// real wake and sleep events, and turning a measured 9:07 start into
    /// 9:05 because someone adjusted the evening would quietly falsify the
    /// record. A day left with one rounded end and one measured one is the
    /// honest result of having rounded one end.
    private func times(span: WorkdaySpan, mode: DragMode, deltaPoints: CGFloat) -> (Date, Date) {
        let delta = Double(deltaPoints) * secondsPerPoint
        var start = span.start
        var end = span.end
        switch mode {
        case .moveWhole:
            start = snap(start.addingTimeInterval(delta))
            end = start.addingTimeInterval(span.end.timeIntervalSince(span.start))
        case .resizeTop:
            start = snap(start.addingTimeInterval(delta))
        case .resizeBottom:
            end = snap(end.addingTimeInterval(delta))
        }

        // Held inside the drawn scale, and never inverted: dragging past the
        // other end used to be thrown away on release, so a drag that went
        // too far simply appeared to do nothing.
        let bounds = chartBounds()
        switch mode {
        case .moveWhole:
            let duration = span.end.timeIntervalSince(span.start)
            let earliest = bounds.lowerBound
            let latest = bounds.upperBound.addingTimeInterval(-duration)
            // A day longer than the drawn scale has nowhere inside it to sit.
            // Shrinking it to fit would throw away hours nobody asked to
            // lose, and sliding it anyway pushed its end past midnight, so
            // moving one simply doesn't apply — resize it first.
            guard latest >= earliest else { return (span.start, span.end) }
            let clamped = min(max(start, earliest), latest)
            return (clamped, clamped.addingTimeInterval(duration))
        case .resizeTop:
            // The far end is clamped too, not just the one being dragged:
            // `WorkdayCalculator` can produce a span that starts before 6am,
            // and resizing the other end would otherwise write that
            // undrawable time straight back out again.
            let fixedEnd = clamp(end, to: bounds)
            var newStart = clamp(start, to: bounds)
            if fixedEnd.timeIntervalSince(newStart) < Self.minimumDuration {
                newStart = fixedEnd.addingTimeInterval(-Self.minimumDuration)
            }
            guard newStart >= bounds.lowerBound else {
                // Only reachable when the end is itself within a quarter hour
                // of the scale's start. The day has to be somewhere, so it
                // takes the minimum from there rather than escaping upwards.
                return (bounds.lowerBound, bounds.lowerBound.addingTimeInterval(Self.minimumDuration))
            }
            return (newStart, fixedEnd)
        case .resizeBottom:
            let fixedStart = clamp(start, to: bounds)
            var newEnd = clamp(end, to: bounds)
            if newEnd.timeIntervalSince(fixedStart) < Self.minimumDuration {
                newEnd = fixedStart.addingTimeInterval(Self.minimumDuration)
            }
            guard newEnd <= bounds.upperBound else {
                return (bounds.upperBound.addingTimeInterval(-Self.minimumDuration), bounds.upperBound)
            }
            return (fixedStart, newEnd)
        }
    }

    private func clamp(_ date: Date, to bounds: ClosedRange<Date>) -> Date {
        min(max(date, bounds.lowerBound), bounds.upperBound)
    }

    /// The window the chart can actually draw, as real times on this day.
    /// Outside it the capsule would stop moving while the pointer kept
    /// going, which read as the drag sticking.
    private func chartBounds() -> ClosedRange<Date> {
        // Built by calendar arithmetic rather than by adding seconds to
        // midnight: on the day the clocks go forward, midnight plus six
        // hours is 7am, and the bars are drawn against wall-clock times.
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: day)
        let first = calendar.date(bySettingHour: Int(ChartScale.startHour), minute: 0, second: 0, of: midnight) ?? midnight
        // The scale's end hour is 24, which is no hour of this day — it's
        // the start of the next one.
        let last = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight
        return first...max(last, first)
    }

    // MARK: - Empty day: accept suggestion or draw a new one

    /// Y-range of the dashed track inside this column, if one is suggested.
    private var suggestedTrackYRange: ClosedRange<CGFloat>? {
        guard let startHour = suggestedStartHour, let endHour = suggestedEndHour,
              endHour > startHour else { return nil }
        let top = CGFloat(ChartScale.fraction(of: startHour)) * chartHeight
        let bottom = CGFloat(ChartScale.fraction(of: endHour)) * chartHeight
        return top...max(bottom, top + barWidth)
    }

    @ViewBuilder
    private func emptyDayView() -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: barWidth + 20, height: chartHeight)
            .contentShape(Rectangle())
            #if os(macOS)
            .background(WindowDragBlocker())
            #endif
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // Don't show a draw preview for a plain click on the
                        // suggested track — that resolves to "accept" on end.
                        if abs(value.translation.height) < Self.tapSlop,
                           let range = suggestedTrackYRange,
                           range.contains(value.startLocation.y) {
                            return
                        }
                        if drawStartY == nil { drawStartY = value.startLocation.y }
                        drawCurrentY = value.location.y
                    }
                    .onEnded { value in
                        defer {
                            drawStartY = nil
                            drawCurrentY = nil
                        }

                        let isTap = abs(value.translation.height) < Self.tapSlop

                        // Click on the empty dotted capsule → place a real
                        // span at those suggested hours.
                        if isTap,
                           let startHour = suggestedStartHour,
                           let endHour = suggestedEndHour,
                           let range = suggestedTrackYRange,
                           range.contains(value.startLocation.y) {
                            let a = snap(date(atHour: startHour))
                            let b = snap(date(atHour: endHour))
                            if a < b { onChange(a, b) }
                            return
                        }

                        // A plain click elsewhere does nothing; only a real
                        // drag draws a custom span.
                        guard !isTap else { return }
                        guard let startY = drawStartY ?? Optional(value.startLocation.y) else { return }
                        let endY = value.location.y
                        let a = date(atY: min(startY, endY))
                        let b = date(atY: max(startY, endY))

                        let snappedA = snap(a)
                        let snappedB = snap(b)
                        if snappedA < snappedB {
                            onChange(snappedA, snappedB)
                        }
                    }
            )
            #if os(macOS)
            .onHover { hovering in
                if hovering { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            #endif
            .overlay(
                Group {
                    if let startY = drawStartY, let currentY = drawCurrentY {
                        let top = min(startY, currentY)
                        let height = max(abs(currentY - startY), barWidth / 2)
                        Capsule()
                            .fill(Self.drawColor)
                            .frame(width: barWidth, height: height)
                            .offset(y: top)
                            .allowsHitTesting(false)
                    }
                }
            )
    }

    /// Converts a raw Y position within `chartHeight` into a real `Date` on
    /// `day`, via `ChartScale`'s inverse mapping.
    private func date(atY y: CGFloat) -> Date {
        date(atHour: ChartScale.hour(atFraction: chartHeight > 0 ? Double(y / chartHeight) : 0))
    }

    private func date(atHour hour: Double) -> Date {
        let hourInt = Int(hour)
        let minuteInt = Int((hour - Double(hourInt)) * 60)
        return Calendar.current.date(bySettingHour: hourInt, minute: minuteInt, second: 0, of: day) ?? day
    }

    /// Rounds to the nearest 15 minutes — coarser than a meeting's 5, since
    /// this is setting the whole workday.
    private func snap(_ date: Date) -> Date {
        let interval: TimeInterval = 15 * 60
        let rounded = (date.timeIntervalSinceReferenceDate / interval).rounded() * interval
        return Date(timeIntervalSinceReferenceDate: rounded)
    }
}
