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
    /// Hosts whose links are a call to join rather than a page about one.
    /// A list rather than "any https link in the notes": invitations are
    /// full of links — dial-in help, calendar policies, someone's
    /// signature — and joining the wrong one wastes exactly the minute you
    /// didn't have.
    private static let conferenceHosts = [
        "zoom.us",
        "zoomgov.com",
        "teams.microsoft.com",
        "teams.live.com",
        "meet.google.com",
        "webex.com",
        "whereby.com",
        "chime.aws",
        "gotomeeting.com",
        "bluejeans.com",
        "around.co",
        "meet.jit.si",
        "discord.gg",
        "slack.com/huddle",
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

    private static func isConference(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let full = url.absoluteString.lowercased()
        return conferenceHosts.contains { candidate in
            candidate.contains("/") ? full.contains(candidate) : host.hasSuffix(candidate)
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
