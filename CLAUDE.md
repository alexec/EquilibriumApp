# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Equilibrium is a sandboxed macOS SwiftUI app (macOS 13+) that infers how many hours
you worked each day from the Mac's sleep/wake events — as up to three shifts a day,
morning, afternoon and evening — annotates those days with calendar meetings, and
holds a dictated intention + check-in per day. See `README.md` for the product
rationale and the "why not `pmset`/`log show`" history.

## Build

The Xcode project is **generated** and git-ignored — `project.yml` is the source of
truth. Never edit `Equilibrium.xcodeproj`; edit `project.yml` and regenerate. New
`.swift` files under `Equilibrium/` are picked up by the directory glob, so adding a
file just needs a regenerate.

```bash
xcodegen generate && xcodebuild -project Equilibrium.xcodeproj -scheme Equilibrium -configuration Debug -destination "platform=macOS" build
```

CI (`.github/workflows/pr-build.yml`, macOS 15 runner) does the same with
`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.

There is **no test target and no tests** — verification is building and running the
app. Several helpers are deliberately pure and `internal` "for testability"
(`WorkdayCalculator`, `WorkloadRecommender`, `WeeklySummaryNotifier.buildMessage`,
`MeetingCalculator`, `WeekCalendar`, `ShiftPlan`) — the app calls them, but there is
no test target to exercise them, so checking one means driving the app or building a
throwaway harness against the source files.

Signing comes from the environment, never from `project.yml` (a team baked in fails
for anyone not in it). Unset, the build signs ad-hoc — which changes the code hash
every build, so macOS re-asks for calendar access each time:

```bash
export EQUILIBRIUM_DEVELOPMENT_TEAM=YOURTEAMID
export EQUILIBRIUM_CODE_SIGN_IDENTITY="Apple Development"
```

## Data flow

```
IOKit power notifications → PowerNotificationMonitor → LiveEventStore (live-events.json, 30-day prune)
                                                            ↓
                                              WorkdayCalculator.computeSpans
                                                            ↓
   EventKit (CalendarStore → MeetingCalculator) → WorkHistoryViewModel → WorkHistoryStore (history.json)
                                                            ↓
                                     ContentView → DailyBarChartView → DayBar, and DayDetailPanel
```

`WorkHistoryViewModel` (`@MainActor`, `ObservableObject`) is the single hub: it owns
the three stores, the 5-minute refresh timer, the 1-minute menu-bar timer, calendar
permission state, the visible week offset, and the day the side panel is editing.
Views are otherwise passed plain values and closures.

Everything is keyed by **`dayKey` — `"yyyy-MM-dd"` in local time**: work spans,
intentions and LLM summaries all use it, and `WorkdaySpan.id`/`DailyIntention.id`
are that key.

State lives in three JSON files plus UserDefaults, all inside the sandbox container
`~/Library/Containers/com.alexcollins.Equilibrium/Data/Library/Application Support/WorkActivityTracker/`:
`live-events.json` (raw power events), `history.json` (computed spans),
`daily-intentions.json`. `WorkPreferences` and the notifier's "already fired this
week" marker go in UserDefaults.

### Rules the data layer enforces

- **Manual edits win.** `WorkdaySpan.isManual` blocks automatic recompute of that
  day entirely; `meetingsManuallyEdited` blocks calendar refresh from overwriting
  hand-dragged meeting blocks. `WorkHistoryStore.merge` and
  `WorkHistoryViewModel.refreshMeetingData` each re-check these independently.
- **History is append-mostly.** `merge` overwrites only today and yesterday; older
  days are added if absent but never recomputed, because their source power events
  age out of the 30-day retention window.
- **A day is up to three shifts, not one block.** `WorkdaySpan.shifts` is the
  source of truth (`WorkShift`, at most `ShiftPlan.maximumShifts`); `start`/`end`
  are computed from it as the day's outer envelope, which is only what meetings
  clip to. `hours` is the shifts added up, so the gaps between them — lunch,
  dinner — are excluded by not being in a shift rather than subtracted afterwards.
  That's why a standard 9–12 / 1–5 day is 7h and the weekly target is 35.
  `effectiveHours` still deducts `breakMinutes`/`intraBreakMinutes`, which now only
  carry break time that couldn't be a gap: pre-shift history, and gaps
  `ShiftPlan.normalize` had to close folding a day of four-plus stretches to three.
- **Every write of a day's shifts goes through `ShiftPlan.normalize`** — sorted,
  merged on overlap *or contact*, folded to three. Merging on contact is the whole
  of the "drag one shift onto the next and they become one" behaviour; nothing
  special-cases the moment they touch.
- **A week is Saturday→Friday**, always exactly seven days (`WeekCalendar`), so
  weekend days sit at the start of the week they belong to. Weekly target, chart
  page, recommendation and digest all work in that unit.
- `WorkdaySpan` and `WorkPreferences` decode every field added since v1 with
  `decodeIfPresent`; keep new fields optional-with-default so existing
  `history.json` files and stored preferences still load. Both have a hand-written
  `init(from:)`/`encode(to:)` carrying pre-shift keys (`start`/`end`,
  `workdayStartHour`/`workdayEndHour`) that are read on the way in and never
  written again — a legacy day becomes one shift, and a legacy 9–5 window becomes
  a morning and an afternoon with the lunch hour taken off the weekly target.

## On-device LLM

`FoundationModels` is used for three optional touches: the week header caption
(`WeeklyInsightGenerator`), a day's meeting gist (`MeetingSummaryGenerator`), and
free-text parsing of work preferences (`WorkPreferencesGenerator`).

- **Every feature needs a non-LLM path**, not an error message — most Macs can't run
  the model. See `WeekHeaderStats.fallbackSentence` and `WorkPreferencesForm`.
- **Guard the whole reference, not just the import.** The framework is missing from
  pre-macOS-26 SDKs (CI's included), so all FoundationModels types live behind
  `#if canImport(FoundationModels)` *and* `@available(macOS 26.0, *)`. A `#available`
  check alone is runtime-only and will not compile on CI.
- `OnDeviceModel` is the only place that answers "is the model usable, and if not
  why" — route new checks through it. Set `EQUILIBRIUM_NO_ON_DEVICE_MODEL=1` to
  force the unavailable path while developing on a Mac that has the model.
- Generated text is validated before display, because the model does get it wrong:
  the week caption is discarded if it contradicts its own figures or runs long, and
  a meeting gist containing a digit is rejected. Keep that shape for new prompts.

## Sandbox and privacy constraints

App Sandbox is on and there is **no network entitlement** — don't add one, and don't
add a dependency that needs it. Entitlements are exactly: sandbox, calendars,
audio-input. No subprocesses (that's why `pmset -g log` backfill was dropped), no
Full Disk Access. Speech recognition is pinned to `requiresOnDeviceRecognition`;
falling back to Apple's servers would break the app's stated promise and fail anyway
without networking. EventKit is read-only in practice — the app never writes events.

## AppKit workarounds worth knowing before "simplifying" them

Each of these exists because the SwiftUI route failed; the reasoning is in the code
comments.

- `MenuBarExtra` labels don't track an `ObservableObject` — a child view renders once
  and keeps what it was given. That's why the menu-bar line is composed in the view
  model as published `menuBarText`/`menuBarAccessibilityLabel` and read in the App's
  own `body`. (A `TimelineView` wrapper removes the menu bar item altogether.)
- `openWindow(id:)` appends a window every call, and SwiftUI opens two at launch
  anyway: `MainWindow.present` raises the existing window, and `WindowChromeRemover`
  closes the duplicate.
- `WeekSwipe` uses a local AppKit event monitor with `hitTest` returning nil — a view
  in front to catch two-finger scrolls would also swallow the clicks that drag
  meeting blocks.
- `WindowDragBlocker` in `DayBar.swift` exists because the window is
  `isMovableByWindowBackground` (hidden title bar), which otherwise steals drags.

## Conventions

Comments explain *why*, at length, in prose — including rejected alternatives and
bugs the shape guards against. Match that when touching this code; a change that
invalidates a comment must update it.

Commit subjects are plain sentences describing the user-visible change, not
conventional-commit prefixes ("Say whether the meeting is happening now or is next").
Work lands via PRs against `main`, and the PR body explains the reasoning at the same
length as the comments.
