import Foundation

/// A user-driven power event: either the machine being woken (start of
/// activity) or put to sleep (end of activity).
struct PowerEvent {
    enum Kind {
        case wake
        case sleep
    }
    let kind: Kind
    let date: Date
}

/// Parses `pmset -g log` for genuine user-initiated wake/sleep events,
/// filtering out DarkWake and Maintenance Sleep entries which fire every
/// ~15 minutes regardless of user presence.
enum WakeLogParser {
    private static let wakeLineRegex = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) [+-]\d{4}\s+Wake\s"#
    )
    private static let sleepLineRegex = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) [+-]\d{4}\s+Sleep\s"#
    )

    /// User-driven wake reasons. Excludes pure maintenance/rtc/alarm wakes that
    /// aren't preceded by "DarkWake" but also aren't the user touching the machine.
    private static let userWakeMarkers = ["HID Activity", "UserActivity Assertion", "Lid Open", "Power Button"]

    /// "DarkWake to FullWake" marks the machine actually becoming interactive
    /// (screen on, user present) after a period of background-only DarkWake.
    /// It must be matched separately from userWakeMarkers because the line
    /// contains the substring "DarkWake", which the plain maintenance-DarkWake
    /// exclusion below would otherwise reject.
    private static let fullWakeTransitionMarker = "DarkWake to FullWake"

    /// User-driven sleep reasons. Excludes "Maintenance Sleep", which the
    /// system enters on its own on a ~15 minute cycle regardless of use.
    private static let userSleepMarkers = ["Clamshell Sleep", "Idle Sleep", "Software Sleep"]

    static func fetchUserPowerEvents() -> [PowerEvent] {
        // pmset's large output combined with in-process Pipe reads has proven
        // unreliable at process-startup timing; writing to a temp file via a
        // shell redirect sidesteps pipe-buffer/fd-race issues entirely.
        for attempt in 1...5 {
            let output = runPmsetLogViaTempFile()
            if !output.isEmpty {
                return parse(output)
            }
            if attempt < 5 {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        return []
    }

    private static func runPmsetLogViaTempFile() -> String {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmset-log-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/usr/bin/pmset -g log > \(tempURL.path) 2>/dev/null"]

        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()

        guard let data = try? Data(contentsOf: tempURL) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    static func parse(_ log: String) -> [PowerEvent] {
        var events: [PowerEvent] = []

        log.enumerateLines { line, _ in
            let isFullWakeTransition = line.contains(fullWakeTransitionMarker)
            let isPureDarkWake = line.contains("DarkWake") && !isFullWakeTransition
            let isUserDriven = isFullWakeTransition || userWakeMarkers.contains(where: { line.contains($0) })

            if !isPureDarkWake, isUserDriven,
               let date = extractDate(from: line, using: wakeLineRegex) {
                events.append(PowerEvent(kind: .wake, date: date))
                return
            }

            if userSleepMarkers.contains(where: { line.contains($0) }),
               let date = extractDate(from: line, using: sleepLineRegex) {
                events.append(PowerEvent(kind: .sleep, date: date))
            }
        }

        return events.sorted { $0.date < $1.date }
    }

    private static func extractDate(from line: String, using regex: NSRegularExpression) -> Date? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return formatter.date(from: String(line[range]))
    }
}
