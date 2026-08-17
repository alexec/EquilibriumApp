import Foundation

/// A user-driven power event: either the machine being woken (start of
/// activity) or put to sleep (end of activity).
///
/// Events are captured live by `PowerNotificationMonitor` (IOKit) and
/// persisted by `LiveEventStore`. There is no historical backfill: the
/// app is sandboxed and cannot shell out to `pmset -g log`, so history
/// accumulates from first launch onward.
struct PowerEvent {
    enum Kind {
        case wake
        case sleep
    }
    let kind: Kind
    let date: Date
}
