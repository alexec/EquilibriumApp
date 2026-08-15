# Equilibrium

A macOS menu-free app that shows how many hours you've worked each day —
computed automatically from your Mac's sleep/wake activity, no manual
tracking required.

![Equilibrium screenshot](docs/screenshot.png)

## Why

I felt like I was working too many hours at the same time I knew those
extra hours weren't producing fantastic extra output. I didn't feel
focused in my work. I wanted a way to make sure I didn't work too hard,
and that would also push me at the same time to be focused in my work.

Encouraging you to work the right number of hours both helps you to
focus and to relax, and to get the right work-life balance.

## How it works

- Tracks sleep/wake events in real time via IOKit power notifications
  (`IORegisterForSystemPower`) — no Full Disk Access required.  Events are
  persisted to disk so history accumulates across app restarts.
- Optionally backfills history from `pmset -g log` when Full Disk Access is
  granted, pre-populating the chart with data from before the app's first run.
- Persists computed days to disk so history survives even after macOS
  rolls the underlying wake/sleep log off its own short retention window.
- Shows a rolling 2-week bar chart, styled after Apple Health's activity
  charts — each day's bar spans its actual start-to-end time, scaled
  6 AM–midnight, colored gray normally and red on weekends or any day
  over 8 hours.
- Recommends how many hours to work on remaining days this week to land
  on a 40-hour week — filling at 8h/day until the budget's used up, or
  flagging when you're already over.
- Days can be manually edited, overridden, or deleted, with an optional
  30-minute-increment break duration subtracted from the displayed hours.
- Follows the system's light/dark appearance automatically.

## Requirements

- macOS 13.0+
- **No special permissions required** for live tracking — IOKit power
  notifications work out of the box.
- Full Disk Access (System Settings → Privacy & Security → Full Disk Access)
  is **optional**: granting it enables `pmset -g log` historical backfill so
  the chart is populated with data from before the app's first launch.  Without
  it the chart fills in automatically as the machine sleeps and wakes while the
  app is running.

## Architecture: two-tier power-event collection

### Live tracking — IOKit (no FDA required)

`PowerNotificationMonitor` registers with the root power domain via
`IORegisterForSystemPower`.  The kernel delivers callbacks on a Mach
notification port (added to the main run loop) for three message types:

| Message | Hex | Meaning |
|---|---|---|
| `kIOMessageCanSystemSleep` | `0xe0000270` | Idle-sleep gate — must acknowledge |
| `kIOMessageSystemWillSleep` | `0xe0000280` | Imminent sleep — must acknowledge |
| `kIOMessageSystemHasPoweredOn` | `0xe0000300` | Wake complete |

Both sleep messages are immediately acknowledged with `IOAllowPowerChange` so
the machine is never held up.  Each event is timestamped at the moment the
callback fires and appended to `LiveEventStore` (a small JSON file in
`~/Library/Application Support/WorkActivityTracker/live-events.json`), so
events persist across app restarts.  Events older than 30 days are pruned
automatically on every write.

### Historical backfill — pmset (FDA required, optional)

At every refresh, the app also attempts `pmset -g log` via `WakeLogParser`.
This call silently returns an empty array when Full Disk Access has not been
granted, so it degrades gracefully.  When FDA *is* granted, pmset provides
the full system power log (typically the last few days up to several weeks)
which pre-populates the chart before the IOKit monitor has had a chance to
build up its own history.

### Merging the two sources

`WorkHistoryViewModel.mergedEvents(live:pmset:)` combines both lists.  pmset
timestamps are preferred when the same physical event appears in both sources
(same kind within 60 s of each other), since pmset records the kernel's own
timestamp rather than the moment the app received the notification.

### Why not `log show`?

`log show --predicate 'eventMessage contains "Wake"' --style syslog` can
surface the same kernel power events from the unified log, but requires the
`com.apple.private.logging.admin` private entitlement for anything beyond the
last few minutes — effectively the same or higher barrier than FDA.  IOKit
notifications are the correct public API for real-time power-state monitoring.

## Building

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to
generate the Xcode project from `project.yml`:

```bash
xcodegen generate
xcodebuild -project Equilibrium.xcodeproj -scheme Equilibrium -configuration Release build
```
