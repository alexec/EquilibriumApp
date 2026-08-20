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
- Persists computed days to disk so history survives even after macOS
  rolls the underlying wake/sleep log off its own short retention window.
- A day is up to three shifts — morning, afternoon and evening — and the
  gaps between them are the breaks.  Lunch isn't worked time subtracted from
  a longer block; it's simply the space where no shift is, which is why a
  standard 9–12 / 1–5 day comes to seven hours rather than eight.
- Shows one week at a time, styled after Apple Health's activity charts —
  each shift a capsule at its actual times, scaled 6 AM–midnight, colored
  gray normally and red on weekends or any day over seven hours.
- Step back through earlier weeks by swiping two fingers across the chart,
  with ⌘[ and ⌘], or with the arrows above it — weeks slide in from the
  side they sit on.
- The shifts a day hasn't got are drawn as dashed ghosts at the hours they
  normally occupy (9–12, 1–5, 6–10 by default).  Click one to put a real
  shift there; drag its top edge to move the start, its bottom edge the end,
  or its middle the whole thing.  Extend a shift until it reaches the next
  and the two become one — which is how a day that turned out to have no
  lunch in it gets recorded as such.  ⌥-click a shift to remove it, and drag
  across bare column to draw one at times no template covers.
- Recommends how many hours to work on remaining days this week to land on
  a 35-hour week — seven hours a weekday, laid into the shifts in order, so
  the ghosts on an untouched day show the morning and the afternoon and
  leave the evening alone.  A week that's fallen behind reaches into the
  evening by itself; a week already over budget says so instead.
- Days can be manually edited, overridden, or deleted.
- Every day carries a morning intention and an end-of-day check-in, typed
  or spoken. Click a day — its bar, its date, anywhere in its column, on any
  day and not just today — to bring it up in the panel beside the chart,
  with both of those and its meetings.
- A day with more than four meetings arrives summarised — "5 meetings ·
  10½h", plus a short phrase from the on-device model where there is one —
  with the full list one click away, so a heavy diary doesn't crowd out
  the day's intention.
- Intentions and check-ins can be **typed or dictated**: click into a field
  to write, or press the microphone beside it and speak.  Recognition runs
  on-device, so the audio is transcribed on your Mac and nothing is
  recorded or sent anywhere.
- The panel is always there, on today to begin with, and follows the chart
  to the same weekday as you page through weeks.  There's nothing to save:
  what you enter is written as you go.
- Follows the system's light/dark appearance automatically.
- Uses Apple's on-device LLM where it exists, but never depends on it: on
  macOS before 26, on Intel Macs, and with Apple Intelligence turned off,
  the weekly caption falls back to a plain stats sentence and work
  preferences are set with ordinary controls instead of free text.

## Requirements

- macOS 13.0+

## Permissions

Equilibrium runs in the **App Sandbox** and asks for as little as it can.

| Permission | Required? | Why |
|---|---|---|
| Calendar (full access) | Optional | Splits tracked time into meetings vs. focus, and writes focus blocks you ask for.  Decline and the app still tracks hours; bars just aren't annotated with meetings. |
| Notifications | Optional | Daily intention / check-in reminders and the weekly summary. |
| Microphone + Speech Recognition | Optional | Only for dictating.  Recognition is pinned on-device, so audio never leaves the Mac and no recording is kept.  Typing needs no permission. |
| Automation (Mail) | Optional | Reads the inbox — subjects, senders, recipients and body text — to summarise what needs doing, and archives a message when you ask it to.  Decline and the inbox column says so; nothing else changes. |
| Reminders | Optional | Only when you defer an email: the reminder carries the date and a link back to the message.  Asked for the first time you defer, not at launch. |
| Full Disk Access | **Never asked for** | Not used. |

Notes:

- Calendar access is **read-mostly** — the app never modifies or deletes an
  event that already exists.  The single exception is the focus block you
  create yourself from a message in the inbox column, which is added as a new
  event marked *free*: your diary shows the time as taken, while Equilibrium
  goes on counting it as focus rather than as a meeting.  EventKit exposes no
  narrower read tier than "full access":
  the only alternative, write-only, cannot read events at all, so the wording
  of the macOS prompt is broader than what the app actually does.
- Mail access is **read, plus archiving on request** — archiving moves the
  message to your account's Archive mailbox, exactly as Mail's own Archive
  button does, so it can be found again and put back.  The app never sends a
  message, never deletes one, and never marks one read.  Deferring an email
  flags it, so Mail shows you which ones you've put off — the date itself goes
  to Reminders, because Mail's own Remind Me is not scriptable.  It goes
  through
  Apple Events rather than reading `~/Library/Mail`, which would need Full
  Disk Access: a grant covering every file on the Mac, to read one folder.
  The entitlement names `com.apple.mail` and nothing else, so what macOS
  records is permission to control Mail specifically.  Only Mail.app is
  supported — mail read in a browser or another client isn't visible to it.
- Message **bodies are never written to disk**.  They're held in memory long
  enough for the on-device model to read them and are then dropped;
  `mail-summaries.json` keeps the conclusion — one line about what to do, and
  a due date — and never the message.
- The sandbox confines all app data to
  `~/Library/Containers/com.alexcollins.Equilibrium/`.  The app has **no
  network entitlement** — the weekly caption is generated by the on-device
  FoundationModels LLM when that's available, so nothing leaves your Mac
  either way.

## Architecture: power-event collection

### Live tracking — IOKit

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

### Why not `pmset -g log`?

Earlier versions shelled out to `pmset -g log` to backfill history from before
the app's first launch.  That required running **unsandboxed** (to spawn a
subprocess) and, in practice, Full Disk Access to read the whole log — a large
grant for a convenience feature.  The backfill was dropped in favour of the
sandbox: the chart now fills in from first launch onward as the machine sleeps
and wakes, and `WorkHistoryStore` keeps those days permanently.

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

### Signing, and why the permission prompts keep coming back

Out of the box the build is signed ad-hoc, which is fine for CI and for
anyone building a fork.  It does mean macOS sees each rebuild as a
different app: a permission grant is recorded against an app's code
signature, and an ad-hoc signature is only its code hash.  So every
rebuild asks for calendar access again.

To stop that while developing, sign with your own team — set these before
`xcodegen generate` and the settings are baked into the project:

```bash
export EQUILIBRIUM_DEVELOPMENT_TEAM=YOURTEAMID
export EQUILIBRIUM_CODE_SIGN_IDENTITY="Apple Development"
```

Your team ID is the `OU` field of your development certificate:

```bash
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```
