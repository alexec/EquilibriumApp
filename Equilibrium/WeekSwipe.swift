import SwiftUI
import AppKit

enum WeekSwipeDirection {
    case previous
    case next
}

extension View {
    /// Pages between weeks when two fingers are swiped horizontally
    /// anywhere over this view, matching the ‹ › buttons and ⌘[ / ⌘].
    func onWeekSwipe(_ perform: @escaping (WeekSwipeDirection) -> Void) -> some View {
        background(WeekSwipeCatcher(onSwipe: perform))
    }
}

/// Trackpad swipe handling for the chart. SwiftUI has no scroll-gesture
/// API on macOS 13, and `DragGesture` sees only click-drags, not a
/// two-finger swipe — so this drops to AppKit for the raw scroll events.
///
/// It watches events with a local monitor rather than by receiving them as
/// a view, because a view that's in front to catch scrolls is also in front
/// to swallow clicks, which would break dragging meeting blocks and the
/// chevrons. `hitTest` returns nil so the view is invisible to the mouse;
/// the monitor then filters on window and frame to the same region the view
/// covers, giving "scrolls over the chart" without touching anything else.
private struct WeekSwipeCatcher: NSViewRepresentable {
    let onSwipe: (WeekSwipeDirection) -> Void

    func makeNSView(context: Context) -> SwipeMonitorView {
        SwipeMonitorView(onSwipe: onSwipe)
    }

    func updateNSView(_ nsView: SwipeMonitorView, context: Context) {
        nsView.onSwipe = onSwipe
    }

    static func dismantleNSView(_ nsView: SwipeMonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

final class SwipeMonitorView: NSView {
    var onSwipe: (WeekSwipeDirection) -> Void

    private var monitor: Any?
    /// Horizontal distance travelled in the current gesture.
    private var accumulated: CGFloat = 0
    /// One page per gesture: without this, a long swipe keeps crossing the
    /// threshold and skips several weeks at once.
    private var firedThisGesture = false
    private var lastWheelFire: Date = .distantPast

    /// How far a swipe must travel before it pages. Far enough not to fire
    /// on the sideways drift of a mostly-vertical scroll, short enough that
    /// a deliberate flick lands.
    private static let threshold: CGFloat = 45
    /// Notched mouse wheels send discrete events with no gesture phases to
    /// bracket them, so those page on a cooldown instead of a threshold.
    private static let wheelCooldown: TimeInterval = 0.35

    init(onSwipe: @escaping (WeekSwipeDirection) -> Void) {
        self.onSwipe = onSwipe
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Invisible to the mouse: clicks, hovers and meeting-block drags all
    /// pass straight through to the SwiftUI content in front of this view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    deinit { stopMonitoring() }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Swallow the event that pages, so nothing downstream also acts
            // on it; everything else carries on untouched.
            self?.handle(event) == true ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// True when this event paged the week.
    private func handle(_ event: NSEvent) -> Bool {
        // Scrolls in another window (the preferences popover) or outside the
        // chart's own bounds aren't week swipes. `locationInWindow` and the
        // converted bounds are both window coordinates, so they compare
        // directly.
        guard let window, event.window === window else { return false }
        guard convert(bounds, to: nil).contains(event.locationInWindow) else { return false }
        // Momentum keeps arriving after the fingers lift; paging on it would
        // fling through several weeks per swipe.
        guard event.momentumPhase.isEmpty else { return false }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return false }

        guard event.hasPreciseScrollingDeltas else {
            return pageFromWheel(deltaX: event.scrollingDeltaX)
        }

        if event.phase.contains(.began) {
            accumulated = 0
            firedThisGesture = false
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            accumulated = 0
            firedThisGesture = false
            return false
        }

        accumulated += event.scrollingDeltaX
        guard !firedThisGesture, abs(accumulated) >= Self.threshold else { return false }
        firedThisGesture = true
        page(deltaX: accumulated)
        return true
    }

    private func pageFromWheel(deltaX: CGFloat) -> Bool {
        guard abs(deltaX) >= 1, Date().timeIntervalSince(lastWheelFire) > Self.wheelCooldown else { return false }
        lastWheelFire = Date()
        page(deltaX: deltaX)
        return true
    }

    /// A positive delta means the content is being pulled to the right,
    /// which uncovers what sits to its left — earlier weeks. macOS has
    /// already applied the "natural scrolling" setting to the delta, so
    /// this reads correctly whichever way that's set.
    private func page(deltaX: CGFloat) {
        onSwipe(deltaX > 0 ? .previous : .next)
    }
}
