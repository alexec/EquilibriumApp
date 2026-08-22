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

/// One shift the day is being offered but doesn't have: a dashed outline at
/// the hours it would occupy, which is also its own click target.
struct GhostShift: Identifiable {
    let id: ShiftTemplate.Slot
    let startHour: Double
    let endHour: Double
}

/// A single day's vertical bar: its shifts drawn at their real times, with
/// a dashed ghost wherever the day could hold another one.
///
/// A day holds up to three shifts — morning, afternoon, evening. Clicking a
/// ghost puts a real shift there; dragging a shift's top edge moves its
/// start, its bottom edge its end, and its middle the whole thing. Extend
/// one shift until it reaches the next and the two become one, which is how
/// a day that turned out to have no lunch in it gets recorded as such.
/// The gaps between shifts are the breaks, and they're simply absent from
/// the day's hours rather than subtracted from them afterwards.
///
/// Meetings (real calendar times) are drawn as separate blocks on top
/// (yellow normally; a lighter red on fiery days so they stay compatible
/// with the shift capsules). They're annotations, not controls — see
/// `MeetingBlockView`. There's no "focus" segment: it was always a derived
/// guess (effective hours minus meetings), never a directly known quantity.
struct DayBar: View {
    let span: WorkdaySpan?
    /// The calendar day this bar represents — needed to construct real
    /// times (not just hour-of-day) when the user adds or draws a shift.
    let day: Date
    let chartHeight: CGFloat
    let isWeekend: Bool
    let barWidth: CGFloat
    let showsWorkdayTrack: Bool
    let recommendedHours: Double?
    /// The configured shift slots (from `WorkPreferences`) the ghosts are
    /// drawn from.
    let shiftTemplates: [ShiftTemplate]
    /// Called when a press on the bar turns out to have been a plain click
    /// — on a shift, on a meeting, or on the bare track — which is how a
    /// day is opened in the side panel. A click on a ghost is not one of
    /// these: that outline is an offer, and accepting it is what it's for.
    var onSelect: () -> Void = {}
    /// Called with a shift's id and its new (start, end) once a drag on it
    /// ends.
    var onShiftChange: (UUID, Date, Date) -> Void = { _, _, _ in }
    /// Called when a ghost is clicked or a new shift drawn from scratch.
    var onShiftAdd: (Date, Date) -> Void = { _, _ in }
    /// Called when a shift is ⌥-clicked, or deleted from its menu.
    var onShiftRemove: (UUID) -> Void = { _ in }
    /// Called when the whole day's hours are deleted from a menu — the same
    /// thing the hover trash under the column does.
    var onDeleteDay: () -> Void = {}

    private var calendar: Calendar { .current }

    private var shifts: [WorkShift] { span?.shifts ?? [] }

    /// Whether to show the recommendation instead of the plain shift
    /// template: only when there's no real work on this day yet.
    private var showsRecommendation: Bool {
        recommendedHours != nil && shifts.isEmpty
    }

    /// The shifts on offer. On an untouched day with a recommendation, the
    /// ghosts are that recommendation laid into the slots in order — seven
    /// hours fills the morning and the afternoon and leaves the evening
    /// alone, and a week that's fallen behind reaches into the evening by
    /// itself. Otherwise every slot the day hasn't already got a shift in.
    private var ghosts: [GhostShift] {
        guard showsWorkdayTrack, !isWeekend else { return [] }
        guard shifts.count < ShiftPlan.maximumShifts else { return [] }

        if showsRecommendation {
            guard let recommendedHours, recommendedHours > 0 else { return [] }
            var remaining = recommendedHours
            var offered: [GhostShift] = []
            for template in shiftTemplates {
                guard remaining > 0.01 else { break }
                let end = min(template.startHour + remaining, template.endHour)
                guard end > template.startHour else { continue }
                offered.append(GhostShift(id: template.slot, startHour: template.startHour, endHour: end))
                remaining -= end - template.startHour
            }
            return offered
        }

        var offered: [GhostShift] = []
        for template in shiftTemplates where template.endHour > template.startHour {
            let taken = shifts.contains { shift in
                hourOfDay(shift.start) < template.endHour && hourOfDay(shift.end) > template.startHour
            }
            guard !taken else { continue }
            // Two outlines drawn over each other are two click targets in
            // the same place, and which one you get is whichever the hit
            // test reaches first. The editor and the parser both keep the
            // slots apart, but a schedule stored before they did needn't
            // have, so the chart doesn't rely on it.
            let overlapsOffered = offered.contains {
                template.startHour < $0.endHour && template.endHour > $0.startHour
            }
            guard !overlapsOffered else { continue }
            offered.append(GhostShift(id: template.slot, startHour: template.startHour, endHour: template.endHour))
        }
        return offered
    }

    /// Hours since midnight on `day` — negative before it, past 24 after,
    /// which is what keeps a shift running to midnight comparable with a
    /// template that ends at 24.
    private func hourOfDay(_ date: Date) -> Double {
        date.timeIntervalSince(calendar.startOfDay(for: day)) / 3600.0
    }

    var body: some View {
        // Still asked, though it's no longer drawn here: a day already over
        // budget is offered nothing, and the chart says why under the bar.
        let isOverBudget = showsRecommendation && (recommendedHours ?? 0) < 0

        ZStack(alignment: .top) {
            Capsule()
                .fill(Color.gray.opacity(isWeekend ? 0.05 : 0.1))
                .frame(width: barWidth, height: chartHeight)

            ShiftLayerView(
                shifts: shifts,
                // Nothing to accept on a day you're already over budget on;
                // the red "over Xh" above says so instead.
                ghosts: isOverBudget ? [] : ghosts,
                day: day,
                chartHeight: chartHeight,
                barWidth: barWidth,
                isWeekend: isWeekend,
                // Faint once the day has real work on it: still an offer,
                // but no longer the thing the column is about.
                ghostsAreSubdued: !shifts.isEmpty,
                onSelect: onSelect,
                onChange: onShiftChange,
                onAdd: onShiftAdd,
                onRemove: onShiftRemove,
                onDeleteDay: onDeleteDay
            )

            // Meetings render even on days with no shifts yet (future week
            // days get an empty span that only holds calendar blocks).
            if let span, !span.meetings.isEmpty {
                let fireIntensity = DayFire.intensity(hours: span.roundedUpHours, isWeekend: isWeekend)
                ForEach(span.meetings) { meeting in
                    MeetingBlockView(
                        meeting: meeting,
                        chartHeight: chartHeight,
                        barWidth: barWidth,
                        dayMidnight: calendar.startOfDay(for: day),
                        color: DayFire.meetingColor(intensity: fireIntensity)
                    )
                }
            }

        }
        .frame(width: barWidth + (showsWorkdayTrack ? 10 : 4), height: chartHeight, alignment: .top)
        .contentShape(Rectangle())
    }
}

/// A single meeting, drawn at its real start/end time.
///
/// Purely an annotation: the calendar says when a meeting happens, and
/// nothing here can move, resize or delete one. It doesn't take presses
/// either — every click in a column belongs to the shift layer underneath,
/// so clicking a meeting opens the day in the side panel exactly as
/// clicking the track beside it does, and a shift edge hiding under a
/// meeting block stays draggable.
private struct MeetingBlockView: View {
    let meeting: MeetingBlock
    let chartHeight: CGFloat
    let barWidth: CGFloat
    /// Midnight at the top of the day this block belongs to, so a meeting
    /// running to midnight reaches the bottom of the chart rather than
    /// being read as the 00:00 that starts a day.
    let dayMidnight: Date
    let color: Color

    private static let minBlockHeight: CGFloat = 6

    var body: some View {
        let topOffset = CGFloat(ChartScale.fraction(of: meeting.start, onDayStarting: dayMidnight)) * chartHeight
        let bottomOffset = CGFloat(ChartScale.fraction(of: meeting.end, onDayStarting: dayMidnight)) * chartHeight
        let height = max(bottomOffset - topOffset, Self.minBlockHeight)

        Capsule()
            .fill(color)
            .frame(width: barWidth, height: height)
            .overlay(
                CapsuleHoursLabel(
                    hours: meeting.end.timeIntervalSince(meeting.start) / 3600.0,
                    capsuleHeight: height,
                    width: barWidth,
                    color: DayFire.meetingLabelColor
                )
            )
            .allowsHitTesting(false)
            .offset(y: topOffset)
    }
}

/// The hours a capsule stands for, written across it.
///
/// Only when there's room: a quarter-hour block is a couple of points tall
/// on an eighteen-hour scale, and a number drawn on it would be unreadable
/// and would spill over its neighbours. Short blocks go unlabelled instead
/// — the capsule is still there to be seen and dragged, and its length is
/// its own answer at that size.
///
/// Sized to the bar rather than to the text, so a label that would be wider
/// than the column shrinks to fit rather than pushing into the day either
/// side. Never a hit target: every press in a column belongs to the one
/// gesture underneath it.
private struct CapsuleHoursLabel: View {
    let hours: Double
    let capsuleHeight: CGFloat
    let width: CGFloat
    let color: Color

    /// A 9pt line plus a little air, which is the least that reads as a
    /// number rather than a smudge.
    private static let minimumHeight: CGFloat = 13

    var body: some View {
        if capsuleHeight >= Self.minimumHeight, hours > 0 {
            Text(HoursFormat.string(hours))
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // A point inside the capsule rather than flush to it: at
                // 18pt wide, "1½h" drawn to the full width touched both
                // rounded ends and spilled onto the track behind. Shrinking
                // that one label a little is better than a number that
                // looks like it's falling out of its block.
                .frame(width: max(width - 2, 1))
                .allowsHitTesting(false)
        }
    }
}

/// Heat for a "fiery" day — shades of red once you're over the balanced
/// line (or working a weekend). 0 = calm gray; 1 = full red.
///
/// Not private: the chart's per-day hours label is coloured by the same
/// rule as the capsules it describes, so the two agree about which days
/// count as fiery.
enum DayFire {
    /// Seven, not eight: a standard day is 9–12 and 1–5, and the hour
    /// between them is no longer counted as worked.
    static let balancedHours = 7

    /// 0 under the line; ramps 8→0.25 … 11+→1. Any weekend work is full fire.
    static func intensity(hours: Int, isWeekend: Bool) -> Double {
        if isWeekend, hours > 0 { return 1 }
        guard hours > balancedHours else { return 0 }
        return min(Double(hours - balancedHours) / 4.0, 1.0)
    }

    /// Shift capsule: gray at 0, soft orange-red → deep red as intensity climbs.
    static func workColor(intensity: Double) -> Color {
        guard intensity > 0 else { return .gray }
        let green = 0.42 - intensity * 0.32
        let blue = 0.22 - intensity * 0.14
        return Color(red: 0.90, green: green, blue: blue)
    }

    /// Meeting overlay: yellow on calm days; a brighter coral-red on fiery
    /// days so blocks stay distinct from the shifts without clashing.
    static func meetingColor(intensity: Double) -> Color {
        guard intensity > 0 else { return .yellow }
        let green = 0.52 - intensity * 0.22
        let blue = 0.30 - intensity * 0.12
        return Color(red: 1.0, green: green, blue: blue)
    }

    /// The ink a shift capsule's hours are written in. White reads well on
    /// every shade of the red, but on the calm gray — which is the system
    /// gray, and so is *lighter* in dark mode than in light — it comes to
    /// barely 3:1, under the line for a 9pt label. Dark ink is the other
    /// way round: fine on the gray in both appearances, and muddy on a deep
    /// red. So the label follows the capsule rather than picking one colour
    /// and hoping.
    static func workLabelColor(intensity: Double) -> Color {
        intensity > 0 ? .white : .black.opacity(0.75)
    }

    /// Meetings need no such switch: both the calm yellow and the fiery
    /// coral are light, so dark ink reads on either.
    static let meetingLabelColor = Color.black.opacity(0.75)
}

/// The day's shifts and the ghosts of the ones it hasn't got, with one
/// gesture over the whole column deciding between them.
///
/// That gesture deliberately lives on a stationary container rather than on
/// the capsules: a `DragGesture` measures translation inside its own view,
/// and a capsule moves as a *result* of the drag, so attaching it there
/// measured each frame's movement from an origin that had just shifted —
/// the capsule lagged, then caught up, and tracked the pointer unevenly.
/// Nothing in the container moves while you drag, so the numbers stay
/// honest. It's also the only way ghosts, shifts and bare column can share
/// one press without competing recognizers deciding between them.
private struct ShiftLayerView: View {
    let shifts: [WorkShift]
    let ghosts: [GhostShift]
    let day: Date
    let chartHeight: CGFloat
    let barWidth: CGFloat
    let isWeekend: Bool
    let ghostsAreSubdued: Bool
    let onSelect: () -> Void
    let onChange: (UUID, Date, Date) -> Void
    let onAdd: (Date, Date) -> Void
    let onRemove: (UUID) -> Void
    let onDeleteDay: () -> Void

    private enum DragMode {
        case moveWhole, resizeTop, resizeBottom
    }

    /// What a press landed on, decided once at the start of a gesture and
    /// held for its duration — otherwise a drag would keep re-deciding as
    /// the pointer passed over things.
    private enum Grab: Equatable {
        case shift(UUID, DragMode)
        case ghost(Int)
        case column
    }

    @State private var grab: Grab?
    @State private var dragPointsDelta: CGFloat = 0
    @State private var drawStartY: CGFloat?
    @State private var drawCurrentY: CGFloat?

    /// Grab zones at each end of a capsule. Proportional so a short shift
    /// stays resizable — a fixed 8pt handle vanished entirely on blocks
    /// under ~80 minutes, leaving them movable but not adjustable — and
    /// bounded so a long one still has a middle to grab.
    private static let minHandleHeight: CGFloat = 6
    private static let maxHandleHeight: CGFloat = 14
    /// How far outside a capsule still counts as grabbing it. Applied only
    /// after every exact hit has been ruled out, so two shifts a few points
    /// apart don't have their padded zones decide between them.
    private static let grabPadding: CGFloat = 8
    /// A drag can't shrink a shift below this.
    private static let minimumDuration: TimeInterval = 15 * 60
    /// Below this a press is a click, not a drag: it changes nothing on a
    /// shift, and accepts the outline it landed on.
    private static let tapSlop: CGFloat = 4
    private static let drawColor = Color.gray.opacity(0.5)
    /// However short a shift is, this much of it is drawn — a quarter hour
    /// is under 3pt on an eighteen-hour scale, which is nothing to aim at.
    private var minimumCapsuleHeight: CGFloat { barWidth / 2 }

    private var secondsPerPoint: Double {
        ChartScale.secondsPerPoint(chartHeight: chartHeight)
    }

    // MARK: - Drawing

    var body: some View {
        // Heat from what the drag is doing rather than from what's saved:
        // taken from the stored value, a day dragged over the balanced line
        // stayed calm all the way through and only turned red on release.
        let live = liveShifts
        let liveHours = live.reduce(0.0) { $0 + $1.hours }
        let fire = DayFire.intensity(hours: Int(liveHours.rounded(.up)), isWeekend: isWeekend)
        let workColor = DayFire.workColor(intensity: fire)

        ZStack(alignment: .top) {
            ForEach(ghosts) { ghost in
                let (top, bottom) = ghostBounds(ghost)
                let height = max(bottom - top, minimumCapsuleHeight)
                Capsule()
                    .fill(Color.gray.opacity(ghostsAreSubdued ? 0.08 : 0.18))
                    .overlay(
                        Capsule()
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .foregroundColor(.secondary.opacity(ghostsAreSubdued ? 0.3 : 0.6))
                    )
                    .frame(width: barWidth, height: height)
                    .offset(y: top)
            }

            ForEach(live) { shift in
                let (top, bottom) = shiftBounds(shift)
                let height = max(bottom - top, minimumCapsuleHeight)
                Capsule()
                    .fill(workColor)
                    .frame(width: barWidth, height: height)
                    // `live`, not `shifts`: a shift being dragged shows the
                    // length it would have, the same way its capsule shows
                    // the shape it would have.
                    .overlay(
                        CapsuleHoursLabel(
                            hours: shift.hours,
                            capsuleHeight: height,
                            width: barWidth,
                            color: DayFire.workLabelColor(intensity: fire)
                        )
                    )
                    // On the capsule, closing over its own id. Hung on the
                    // container instead — asking hover which block the
                    // pointer was over — it deleted the wrong shift: the
                    // menu's contents are built when the view updates, not
                    // when the menu opens, so they can carry a target from
                    // an earlier position. A menu that deletes something
                    // other than what was right-clicked is the one failure
                    // this feature can't have, and binding each menu to the
                    // block it's drawn on rules it out by construction.
                    .contextMenu {
                        Button("Delete Shift", role: .destructive) { onRemove(shift.id) }
                        Divider()
                        dayMenuItems
                    }
                    .offset(y: top)
            }

            if let startY = drawStartY, let currentY = drawCurrentY {
                let top = min(startY, currentY)
                let height = max(abs(currentY - startY), minimumCapsuleHeight)
                Capsule()
                    .fill(Self.drawColor)
                    .frame(width: barWidth, height: height)
                    .overlay(
                        CapsuleHoursLabel(
                            hours: abs(Double(currentY - startY)) * secondsPerPoint / 3600.0,
                            capsuleHeight: height,
                            width: barWidth,
                            // The preview is drawn in the same gray a calm
                            // day is, so it takes the calm day's ink.
                            color: DayFire.workLabelColor(intensity: 0)
                        )
                    )
                    .offset(y: top)
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
        .gesture(dragGesture)
        .help(helpText)
        .contextMenu { dayMenuItems }
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                switch resolve(at: point.y) {
                case .shift(_, .resizeTop), .shift(_, .resizeBottom): NSCursor.resizeUpDown.set()
                case .shift(_, .moveWhole): NSCursor.openHand.set()
                case .ghost: NSCursor.pointingHand.set()
                case .column: NSCursor.crosshair.set()
                }
            case .ended:
                NSCursor.arrow.set()
            }
        }
        #endif
    }

    /// The menu for the column itself — bare track, or a ghost. Only the
    /// day is on offer here, since nothing else was clicked. It's disabled
    /// rather than absent on a day with no hours: an empty menu is worse
    /// than a grayed-out one, which at least says the option exists.
    ///
    /// A capsule carries its own copy of this, with its own entry above it;
    /// the innermost menu is the one that opens, so a right-click on a
    /// block gets the block's.
    @ViewBuilder
    private var dayMenuItems: some View {
        Button("Delete Day's Hours", role: .destructive) { onDeleteDay() }
            .disabled(shifts.isEmpty)
    }

    private var helpText: String {
        if shifts.isEmpty {
            return ghosts.isEmpty
                ? "Click to open this day, or drag to record a shift"
                : "Click an outline to add that shift, drag to draw one, or click the bar to open this day"
        }
        return "Click to open this day. Drag a shift's edge to extend it — reach the next one and they merge. Right-click a block to delete it (⌥-click a shift does the same)."
    }

    /// The shifts as they should look right now: saved, except for the one
    /// being dragged, which shows where it would land.
    private var liveShifts: [WorkShift] {
        guard case let .shift(id, mode)? = grab, dragPointsDelta != 0 else { return shifts }
        return shifts.map { shift in
            guard shift.id == id else { return shift }
            let (start, end) = times(shift: shift, mode: mode, deltaPoints: dragPointsDelta)
            return WorkShift(id: shift.id, start: start, end: end)
        }
    }

    /// Measured against this day rather than off the clock: a shift ending
    /// at midnight is stored as the start of the next day, and read as a
    /// time of day that's 00:00 — the top of the chart — which drew six
    /// hours of evening work as a stub back at 6pm.
    private func shiftBounds(_ shift: WorkShift) -> (top: CGFloat, bottom: CGFloat) {
        let midnight = Calendar.current.startOfDay(for: day)
        let top = CGFloat(ChartScale.fraction(of: shift.start, onDayStarting: midnight)) * chartHeight
        let bottom = CGFloat(ChartScale.fraction(of: shift.end, onDayStarting: midnight)) * chartHeight
        return (top, max(bottom, top + minimumCapsuleHeight))
    }

    private func ghostBounds(_ ghost: GhostShift) -> (top: CGFloat, bottom: CGFloat) {
        let top = CGFloat(ChartScale.fraction(of: ghost.startHour)) * chartHeight
        let bottom = CGFloat(ChartScale.fraction(of: ghost.endHour)) * chartHeight
        return (top, max(bottom, top + minimumCapsuleHeight))
    }

    // MARK: - The one gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let target = grab ?? resolve(at: value.startLocation.y)
                if grab == nil { grab = target }

                switch target {
                case .shift:
                    dragPointsDelta = value.translation.height
                case .ghost, .column:
                    // A click on an outline is an acceptance, not a draw, so
                    // it gets no preview until it's clearly become a drag.
                    guard abs(value.translation.height) >= Self.tapSlop else { return }
                    if drawStartY == nil { drawStartY = value.startLocation.y }
                    drawCurrentY = value.location.y
                }
            }
            .onEnded { value in
                let target = grab ?? resolve(at: value.startLocation.y)
                defer {
                    grab = nil
                    dragPointsDelta = 0
                    drawStartY = nil
                    drawCurrentY = nil
                }

                let isTap = abs(value.translation.height) < Self.tapSlop

                switch target {
                case let .shift(id, mode):
                    guard let shift = shifts.first(where: { $0.id == id }) else { return }
                    if isTap {
                        // Removing is deliberate: a plain click on a shift
                        // opens the day rather than changing it, so the
                        // block can be aimed at and missed without a day's
                        // work disappearing.
                        if isOptionHeld { onRemove(id) } else { onSelect() }
                        return
                    }
                    let (start, end) = times(shift: shift, mode: mode, deltaPoints: value.translation.height)
                    onChange(id, start, end)

                case let .ghost(index):
                    if isTap {
                        guard index < ghosts.count else { return }
                        let ghost = ghosts[index]
                        let start = snap(date(atHour: ghost.startHour))
                        let end = snap(date(atHour: ghost.endHour))
                        if start < end { onAdd(start, end) }
                        return
                    }
                    draw(from: value)

                case .column:
                    guard !isTap else {
                        onSelect()
                        return
                    }
                    draw(from: value)
                }
            }
    }

    /// A drag across bare column, or off an outline: a brand-new shift
    /// between the two ends of the gesture, whichever way round they came.
    private func draw(from value: DragGesture.Value) {
        let startY = drawStartY ?? value.startLocation.y
        let endY = value.location.y
        let start = snap(date(atY: min(startY, endY)))
        let end = snap(date(atY: max(startY, endY)))
        if start < end { onAdd(start, end) }
    }

    private var isOptionHeld: Bool {
        #if os(macOS)
        return NSEvent.modifierFlags.contains(.option)
        #else
        return false
        #endif
    }

    /// What a press at `y` has hold of. Shifts win over ghosts, and an
    /// exact hit on either wins over a padded one.
    private func resolve(at y: CGFloat) -> Grab {
        for shift in shifts {
            let (top, bottom) = shiftBounds(shift)
            if y >= top, y <= bottom {
                return .shift(shift.id, mode(y: y, top: top, bottom: bottom))
            }
        }
        for shift in shifts {
            let (top, bottom) = shiftBounds(shift)
            if y >= top - Self.grabPadding, y <= bottom + Self.grabPadding {
                return .shift(shift.id, mode(y: y, top: top, bottom: bottom))
            }
        }
        for (index, ghost) in ghosts.enumerated() {
            let (top, bottom) = ghostBounds(ghost)
            if y >= top, y <= bottom { return .ghost(index) }
        }
        return .column
    }

    /// Which part of a capsule a press at `y` has hold of.
    private func mode(y: CGFloat, top: CGFloat, bottom: CGFloat) -> DragMode {
        let height = bottom - top
        let handle = min(Self.maxHandleHeight, max(Self.minHandleHeight, height / 3))
        if y <= top + handle { return .resizeTop }
        if y >= bottom - handle { return .resizeBottom }
        return .moveWhole
    }

    // MARK: - Drag arithmetic

    /// The one place a drag turns into times — used for both the live
    /// capsule and the value saved on release, so what you let go of is
    /// exactly what you get. Snapping and clamping happen here rather than
    /// on release, which is what stopped the capsule jumping at the end of
    /// every drag.
    ///
    /// Rounding is applied to what the drag actually moves, and nothing
    /// else. Resizing snaps the edge you have hold of and leaves the far
    /// one exactly as it was; moving snaps the start and carries the
    /// original duration with it, so both ends shift together and the shift
    /// keeps its length.
    ///
    /// What that avoids is rounding a time nobody touched: these come from
    /// real wake and sleep events, and turning a measured 9:07 start into
    /// 9:05 because someone adjusted the evening would quietly falsify the
    /// record. A shift left with one rounded end and one measured one is the
    /// honest result of having rounded one end.
    ///
    /// Overlapping a neighbour isn't prevented here: running one shift into
    /// the next is how you say they were really one, and the merge happens
    /// where the day is written (`ShiftPlan.normalize`).
    private func times(shift: WorkShift, mode: DragMode, deltaPoints: CGFloat) -> (Date, Date) {
        let delta = Double(deltaPoints) * secondsPerPoint
        var start = shift.start
        var end = shift.end
        switch mode {
        case .moveWhole:
            start = snap(start.addingTimeInterval(delta))
            end = start.addingTimeInterval(shift.end.timeIntervalSince(shift.start))
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
            let duration = shift.end.timeIntervalSince(shift.start)
            let earliest = bounds.lowerBound
            let latest = bounds.upperBound.addingTimeInterval(-duration)
            // A shift longer than the drawn scale has nowhere inside it to
            // sit. Shrinking it to fit would throw away hours nobody asked
            // to lose, and sliding it anyway pushed its end past midnight,
            // so moving one simply doesn't apply — resize it first.
            guard latest >= earliest else { return (shift.start, shift.end) }
            let clamped = min(max(start, earliest), latest)
            return (clamped, clamped.addingTimeInterval(duration))
        case .resizeTop:
            // The far end is clamped too, not just the one being dragged:
            // `WorkdayCalculator` can produce a shift that starts before 6am,
            // and resizing the other end would otherwise write that
            // undrawable time straight back out again.
            let fixedEnd = clamp(end, to: bounds)
            var newStart = clamp(start, to: bounds)
            if fixedEnd.timeIntervalSince(newStart) < Self.minimumDuration {
                newStart = fixedEnd.addingTimeInterval(-Self.minimumDuration)
            }
            guard newStart >= bounds.lowerBound else {
                // Only reachable when the end is itself within a quarter hour
                // of the scale's start. The shift has to be somewhere, so it
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
    /// Outside it a capsule would stop moving while the pointer kept going,
    /// which read as the drag sticking.
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

    /// Converts a raw Y position within `chartHeight` into a real `Date` on
    /// `day`, via `ChartScale`'s inverse mapping.
    private func date(atY y: CGFloat) -> Date {
        date(atHour: ChartScale.hour(atFraction: chartHeight > 0 ? Double(y / chartHeight) : 0))
    }

    /// Wall-clock, like `ChartScale.fraction(of:)` that it inverts — set as
    /// an hour component rather than added as an interval, so a shift drawn
    /// at 9am on the day the clocks go forward is at 9am and not 10.
    ///
    /// Rounded to whole minutes *before* being split into hour and minute,
    /// the same way `DailyIntentionNotifier` has to: rounding the
    /// fractional part on its own gives 60 for anything within half a
    /// minute of the next hour, and minute 60 matches no date at all. That
    /// returned nil and fell back to midnight at the *top* of the day, so a
    /// drag ending just shy of an hour produced a time before its own
    /// start and was thrown away as inverted — the drag simply did nothing.
    private func date(atHour hour: Double) -> Date {
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: day)
        let totalMinutes = min(max(Int((hour * 60).rounded()), 0), 24 * 60)
        // Midnight is no hour of this day; it's the start of the next one,
        // which `bySettingHour:` can't express.
        guard totalMinutes < 24 * 60 else {
            return calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight
        }
        return calendar.date(
            bySettingHour: totalMinutes / 60, minute: totalMinutes % 60, second: 0, of: midnight
        ) ?? midnight
    }

    /// Rounds to the nearest 15 minutes — coarser than a meeting's 5, since
    /// this is setting a whole shift.
    private func snap(_ date: Date) -> Date {
        let interval: TimeInterval = 15 * 60
        let rounded = (date.timeIntervalSinceReferenceDate / interval).rounded() * interval
        return Date(timeIntervalSinceReferenceDate: rounded)
    }
}
