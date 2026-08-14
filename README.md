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

- Reads `pmset -g log` for genuine user-driven wake/sleep events (filtering
  out background maintenance wakes), and groups them into a contiguous
  workday per calendar day using an 8-hour gap rule: if you're away from
  the machine for 8+ hours, that's the end of the previous day and the
  start of the next.
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
- Full Disk Access granted to the app (System Settings → Privacy &
  Security → Full Disk Access) — required to read the system power log.

## Building

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to
generate the Xcode project from `project.yml`:

```bash
xcodegen generate
xcodebuild -project Equilibrium.xcodeproj -scheme Equilibrium -configuration Release build
```
