import AppKit
import Foundation

/// Opening a message in Mail, which is where you go the moment the summary
/// isn't enough.
///
/// The column deliberately shows no message text, so there has to be a way
/// through to the real thing — otherwise a row that raises a question
/// leaves you searching your inbox for the message you were just looking
/// at. Same reasoning as the camera on a meeting row in `MeetingLinks`:
/// the summary is for deciding, the link is for doing.
enum MailLinks {
    /// Mail addresses a single message by its RFC Message-ID, wrapped in
    /// the angle brackets the header format calls for. Mail's `message id`
    /// property hands the id over without them, so they're added here —
    /// and percent-encoded, since a bare `<` is not legal in a URL.
    ///
    /// Message-IDs contain `@`, and often `+`, `$` and `%` besides, all of
    /// which mean something else in a URL. `urlHostAllowed` would leave
    /// them be; the query set escapes what needs escaping.
    static func messageURL(for identifier: String) -> URL? {
        let trimmed = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !trimmed.isEmpty else { return nil }
        guard let encoded = trimmed.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        ) else { return nil }
        return URL(string: "message://%3C\(encoded)%3E")
    }

    /// Reads a message id back out of one of our own `message://` URLs.
    ///
    /// The inverse of `messageURL(for:)`, and the reason a reminder can be
    /// recognised as a deferred email at all — see `RemindersStore`.
    /// Anything that isn't a `message:` URL belongs to somebody else and
    /// comes back nil.
    static func messageID(from url: URL?) -> String? {
        guard let url, url.scheme == "message" else { return nil }
        let text = url.absoluteString
            .replacingOccurrences(of: "message://", with: "")
            .replacingOccurrences(of: "message:", with: "")
        guard let decoded = text.removingPercentEncoding else { return nil }
        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Shows the message in Mail, falling back to bringing Mail forward
    /// when the message has no usable id — a message with no Message-ID
    /// header is rare but real, and landing in the inbox beats doing
    /// nothing when a row is clicked.
    @MainActor
    static func open(messageID identifier: String) {
        if let url = messageURL(for: identifier) {
            NSWorkspace.shared.open(url)
            return
        }
        if let mail = URL(string: "message://") {
            NSWorkspace.shared.open(mail)
        }
    }
}
