import AppKit
import EventKit
import Foundation

/// Finding the two things you want from a meeting in the menu bar: the call
/// to join, and the event itself in Calendar.
///
/// EventKit has no "conference" field — Calendar.app detects video links by
/// reading the event the same way a person does — so this looks where
/// organisers actually put them: the URL field first, since an event that
/// has one usually means it, then the location, then the notes, where a
/// pasted invitation lands.
enum MeetingLinks {
    /// Hosts whose links are a call to join rather than a page about one,
    /// each with the name to call it by. A list rather than "any https link
    /// in the notes": invitations are full of links — dial-in help, calendar
    /// policies, someone's signature — and joining the wrong one wastes
    /// exactly the minute you didn't have.
    ///
    /// The names are here rather than derived from the host because a host
    /// isn't a name: "teams.microsoft.com" and "meet.google.com" both read
    /// as machine addresses, and the chart's hover tooltip has one word of
    /// room to say what kind of call this is.
    private static let conferenceHosts: [(match: String, name: String)] = [
        ("zoom.us", "Zoom"),
        ("zoomgov.com", "Zoom"),
        ("teams.microsoft.com", "Teams"),
        ("teams.live.com", "Teams"),
        ("meet.google.com", "Google Meet"),
        ("webex.com", "Webex"),
        ("whereby.com", "Whereby"),
        ("chime.aws", "Chime"),
        ("gotomeeting.com", "GoToMeeting"),
        ("bluejeans.com", "BlueJeans"),
        ("around.co", "Around"),
        ("meet.jit.si", "Jitsi"),
        ("discord.gg", "Discord"),
        ("slack.com/huddle", "Slack huddle"),
    ]

    /// The call to join, if this event carries one.
    static func joinURL(for event: EKEvent) -> URL? {
        if let url = event.url, isConference(url) {
            return url
        }
        for text in [event.location, event.notes].compactMap({ $0 }) {
            if let found = firstConferenceURL(in: text) {
                return found
            }
        }
        // An event whose URL field isn't a recognised host still had someone
        // put it there deliberately, so it's better than nothing.
        return event.url
    }

    /// What to call the service behind a join link — "Zoom", "Teams" — or
    /// nil for a URL that isn't a recognised call. Nil covers the fallback
    /// `joinURL` returns for an event with a URL nobody here knows: it's
    /// worth opening, but there's no honest name to put on it.
    static func serviceName(for url: URL) -> String? {
        matchingHost(url)?.name
    }

    private static func isConference(_ url: URL) -> Bool {
        matchingHost(url) != nil
    }

    private static func matchingHost(_ url: URL) -> (match: String, name: String)? {
        guard let host = url.host?.lowercased() else { return nil }
        let full = url.absoluteString.lowercased()
        return conferenceHosts.first { candidate in
            candidate.match.contains("/")
                ? full.contains(candidate.match)
                : host.hasSuffix(candidate.match)
        }
    }

    private static func firstConferenceURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector?.matches(in: text, options: [], range: range) ?? []
        return matches.compactMap(\.url).first(where: isConference)
    }

    /// Opens the event in Calendar. `ical://ekevent/...` is how Calendar
    /// addresses a single event; without a recognised identifier the best
    /// that can be done is to bring Calendar to the front.
    @MainActor
    static func showInCalendar(identifier: String?, on date: Date) {
        guard let identifier, !identifier.isEmpty,
              let url = URL(string: "ical://ekevent/\(identifier)?method=show&options=more") else {
            if let calendar = URL(string: "ical://") {
                NSWorkspace.shared.open(calendar)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func join(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
