import Foundation
import IOKit.pwr_mgt

/// Registers for IOKit system-power notifications and emits live
/// wake/sleep `PowerEvent` values without requiring Full Disk Access.
///
/// The registration is made against the root power domain via
/// `IORegisterForSystemPower`, which delivers callbacks on a dedicated
/// Mach notification port.  No special entitlement is required.
///
/// Typical usage:
/// ```swift
/// let monitor = PowerNotificationMonitor { event in
///     // runs on the main run loop
/// }
/// monitor.start()
/// // … later:
/// monitor.stop()
/// ```
final class PowerNotificationMonitor {
    /// Called on the main run loop each time a user-relevant power event fires.
    var onEvent: ((PowerEvent) -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var notifierObject: io_object_t = 0
    private var rootPort: io_connect_t = 0
    /// The opaque pointer passed as `refCon` to IOKit, retaining `self`.
    /// Balanced by a `release()` call in `stop()`.
    private var retained: UnsafeMutableRawPointer?

    init(onEvent: ((PowerEvent) -> Void)? = nil) {
        self.onEvent = onEvent
    }

    /// Registers for system-power notifications on the current run loop.
    /// Safe to call more than once; subsequent calls are no-ops until `stop()`
    /// is called first.
    func start() {
        guard rootPort == 0 else { return }

        // `IORegisterForSystemPower` returns a connect handle used later for
        // `IOAllowPowerChange`.  It also fills in the notification port and
        // the opaque notifier object needed for deregistration.
        let refCon = Unmanaged.passRetained(self).toOpaque()
        retained = refCon
        rootPort = IORegisterForSystemPower(
            refCon,
            &notifyPort,
            { refCon, _, messageType, messageArgument in
                guard let refCon else { return }
                let monitor = Unmanaged<PowerNotificationMonitor>
                    .fromOpaque(refCon)
                    .takeUnretainedValue()
                monitor.handle(messageType: messageType, messageArgument: messageArgument)
            },
            &notifierObject
        )

        guard rootPort != 0, let port = notifyPort else {
            // Registration failed; balance the retain acquired above.
            if let r = retained {
                Unmanaged<PowerNotificationMonitor>.fromOpaque(r).release()
                retained = nil
            }
            return
        }
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    /// Deregisters all IOKit notifications and tears down the run-loop source.
    func stop() {
        guard rootPort != 0 else { return }

        if let port = notifyPort,
           let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            IONotificationPortDestroy(port)
            notifyPort = nil
        }

        IODeregisterForSystemPower(&notifierObject)
        IOObjectRelease(notifierObject)
        IOServiceClose(rootPort)
        rootPort = 0

        if let r = retained {
            Unmanaged<PowerNotificationMonitor>.fromOpaque(r).release()
            retained = nil
        }
    }

    // MARK: – Private

    private func handle(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        let now = Date()

        // IOKit message-type constants (from <IOKit/pwr_mgt/IOPM.h>):
        //   kIOMessageCanSystemSleep   = 0xe0000270  – idle-sleep gate; must be ack'd
        //   kIOMessageSystemWillSleep  = 0xe0000280  – imminent sleep; must be ack'd
        //   kIOMessageSystemHasPoweredOn = 0xe0000300 – wake complete
        let canSleep   = UInt32(0xe0000270)
        let willSleep  = UInt32(0xe0000280)
        let poweredOn  = UInt32(0xe0000300)

        switch messageType {
        case canSleep, willSleep:
            // Acknowledge first so sleep isn't blocked, then emit the event.
            IOAllowPowerChange(rootPort, Int(bitPattern: messageArgument))
            onEvent?(PowerEvent(kind: .sleep, date: now))

        case poweredOn:
            onEvent?(PowerEvent(kind: .wake, date: now))

        default:
            break
        }
    }
}
