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
   Mail (AppleScript → MailStore → MailSummaryGenerator) ↗    ↓   ↘ MailSummaryStore (mail-summaries.json)
                                                            ↓
                    ContentView → MailColumn, DailyBarChartView → DayBar, DayDetailPanel, PeopleStrip
```

`WorkHistoryViewModel` (`@MainActor`, `ObservableObject`) is the single hub: it owns
the three stores, the 5-minute refresh timer, the 1-minute menu-bar timer, calendar
permission state, the visible week offset, and the day the side panel is editing.
Views are otherwise passed plain values and closures.

Everything is keyed by **`dayKey` — `"yyyy-MM-dd"` in local time**: work spans,
intentions and LLM summaries all use it, and `WorkdaySpan.id`/`DailyIntention.id`
are that key.

State lives in four JSON files plus UserDefaults, all inside the sandbox container
`~/Library/Containers/com.alexcollins.Equilibrium/Data/Library/Application Support/WorkActivityTracker/`:
`live-events.json` (raw power events), `history.json` (computed spans),
`daily-intentions.json`, and `mail-summaries.json` (one action line and due
date per message id — **never a body or a subject**, 30-day prune). `WorkPreferences` and the notifier's "already fired this
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

## Reading Mail

`MailStore` is the only thing that talks to Mail, over one `NSAppleScript` per
fetch. Three things about it are load-bearing and were each learned by the
script failing:

- **No scripting additions, ever.** The sandbox refuses to load `.osax` bundles,
  so `current date` and friends are unavailable — and inside a `tell application
  "Mail"` block the unresolved command is sent to *Mail*, which never answers it,
  killing the whole script with `-1712 AppleEvent timed out` before it reads
  anything. "Now" is computed in Swift and interpolated in.
- **Never run it on the main thread.** The first call is the one macOS puts the
  Automation consent prompt in front of, and that prompt needs the main thread to
  draw. Waiting for consent on the main thread deadlocks with no dialog visible.
- **Plural gets need the specifier, not a variable holding it.** `set m to
  messages 1 thru 40 of inbox` resolves to a list, and `subject of <list>` is
  `-1728`. Repeating the range in each get is what keeps it to one Apple Event
  per property instead of one per message.

Message bodies are read into memory and never persisted; `MailSummaryStore`
holds conclusions only.

Which account is read is re-read from UserDefaults for every script rather than
cached in a property: the picker writes it on the main thread and the script
builders read it on `MailStore.queue`, and the visible form of that race is a
fetch reading the mailbox you just switched away from. For the same reason
`WorkHistoryViewModel.refreshMail` throws away a fetch whose answer arrives after
the account changed, and queues a refresh asked for while one is running instead
of dropping it — dropping it meant switching account left the column empty until
the five-minute timer came round.

Mail is read-only with **one** exception: `MailStore.archive` sets a message's
`mailbox` to its account's Archive (Mail has no `archive` verb — its own button
is a move too). Nothing sends, deletes, or marks mail read; keep it that way.

Deferring is **not** Mail's Remind Me: that feature isn't in the scripting
dictionary at all — no command, no property — and the only message state Apple
Events can write is read status, flags, junk status and mailbox. So a deferral
is written to **Reminders** (`RemindersStore`), with the reminder's `url` set
to the message's `message://` address; that URL is also how deferrals are read
back, and how a reminder completed on a phone brings the message back here.
The message is flagged in Mail as well, which is the only marker Apple Events
can write that you'll see when you open Mail. Nothing about a deferral is
stored by this app. `MailDeferral.isHidden` is the only rule: hidden while the
deferral is on a *later day* than today, so anything due today is on screen.

## On-device LLM

`FoundationModels` is used for optional touches: the week header caption
(`WeeklyInsightGenerator`), a day's meeting gist (`MeetingSummaryGenerator`),
free-text parsing of work preferences (`WorkPreferencesGenerator`), a per-message
action line (`MailSummaryGenerator`) and the day brief above the inbox
(`DayBriefGenerator`).

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
- **Put nothing quotable in a prompt.** Given example actions, the model returned
  one word for word on three unrelated messages; given the list of verbs that
  replaced them, it returned a bare verb on five in a row. `MailSummaryGenerator`
  now names no phrase and no verb, sets a floor as well as a ceiling on length,
  and checks the answer shares a real word with the message it describes.
- **Cached generated text is versioned.** `MailSummaryGenerator.promptVersion` is
  stored with each summary; bump it when the prompt or validation changes, or
  `mail-summaries.json` serves lines written by a prompt that no longer exists.
- Where a date is involved, the detector finds the candidates
  (`MailDueDates`) and the model only picks one by number — same principle as
  handing `WeeklyInsightGenerator` a worked-out comparison rather than two
  numbers to subtract.

## Sandbox and privacy constraints

App Sandbox is on and there is **no network entitlement** — don't add one, and don't
add a dependency that needs it. Entitlements are exactly: sandbox, calendars,
audio-input, and Apple Events scoped by temporary exception to `com.apple.mail`.
No subprocesses (that's why `pmset -g log` backfill was dropped), no
Full Disk Access — reading `~/Library/Mail` directly would need it, which is why
mail comes over Apple Events instead. Speech recognition is pinned to `requiresOnDeviceRecognition`;
falling back to Apple's servers would break the app's stated promise and fail anyway
without networking. EventKit is **read-mostly**: it writes exactly two things, and
never *edits* an event, so an invitation's time, title or attendees can't be
changed behind your back.

- A focus block (`CalendarStore.createFocusBlock`), created from a message in the
  inbox column. Blocks are written with `availability = .free`, which is not a
  convention but the app's actual definition of "not a meeting" — `meetingEvents`
  filters free events out, so blocked focus time claims the slot in your diary
  without moving the meeting figures it was meant to reduce.
- A deletion (`CalendarStore.delete`), from the meeting popover in the day panel,
  behind a second confirmation. It finds the occurrence by day and start time
  rather than by `event(withIdentifier:)`, which for a repeating meeting hands
  back the series rather than the occurrence you were looking at.

**There is no accept or decline, and there can't be.** No API a sandboxed app can
reach answers an invitation: `EKParticipant.participantStatus` is read-only, and so
is `participation status` in Calendar's own AppleScript dictionary. Sending the
iTIP reply ourselves would need the network entitlement this app doesn't have, or
an outgoing mail it will never send. So deleting a meeting is not declining it —
the popover says so — and RSVP stays one click away in Calendar. Don't add two
buttons that only pretend.

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
