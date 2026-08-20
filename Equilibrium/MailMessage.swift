import Foundation

/// Someone on the other end of a message or a meeting.
///
/// Identity is the address, lowercased: the same human arrives as "Alex
/// Collins", "alex collins" and no name at all depending on whether the
/// sender set a display name and which header a given message put them in,
/// and three chips for one person is worse than one chip with the wrong
/// capitalisation. The name is carried alongside for display only, and the
/// best one seen wins (see `mergingDisplayName(with:)`).
struct Person: Hashable, Identifiable {
    /// Lowercased, trimmed — the identity.
    let address: String
    /// As written by whoever sent it, when they wrote one at all.
    let name: String?

    var id: String { address }

    init(address: String, name: String? = nil) {
        self.address = address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmedName?.isEmpty ?? true) ? nil : trimmedName
    }

    /// Only the address takes part in identity; two records of one person
    /// differing in display name are the same person.
    static func == (lhs: Person, rhs: Person) -> Bool { lhs.address == rhs.address }
    func hash(into hasher: inout Hasher) { hasher.combine(address) }

    /// What to put on screen. Falls back to the local part with its
    /// separators opened out — "alex.collins" reads as a name, and
    /// "alex.collins@example.com" is a line of chip nobody has room for.
    var displayName: String {
        if let name { return name }
        let localPart = address.split(separator: "@").first.map(String.init) ?? address
        let words = localPart
            .split(whereSeparator: { ".-_+".contains($0) })
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return address }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Up to two letters for a chip: initials where there's a real name,
    /// otherwise the first letter of the address.
    var initials: String {
        let words = displayName.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// The same person, keeping whichever record actually has a name.
    func mergingDisplayName(with other: Person) -> Person {
        Person(address: address, name: name ?? other.name)
    }

    /// Parses the one-line form Mail hands back for a sender —
    /// `Alex Collins <alex@example.com>`, or a bare address when the sender
    /// set no display name. Quotes around the name are stripped: they're
    /// how a name containing a comma is escaped, not part of the name.
    static func parse(_ raw: String) -> Person? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        guard let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close else {
            return text.contains("@") ? Person(address: text) : nil
        }
        let address = String(text[text.index(after: open)..<close])
        let name = text[text.startIndex..<open]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard address.contains("@") else { return nil }
        return Person(address: address, name: name)
    }
}

/// One message from the inbox, as far as this app cares about it.
///
/// `bodyExcerpt` is the exception to everything else here: it exists to be
/// read once by the summariser and then forgotten. It is never persisted —
/// see `MailSummaryStore` — so the only copy of your mail on disk remains
/// Mail's own.
struct MailMessage: Identifiable, Equatable {
    /// Mail's `message id` header. Stable across launches and across
    /// mailboxes, which is what makes a summary cache possible.
    let id: String
    let subject: String
    let sender: Person
    /// Everyone else on the message — To and Cc, minus you. This is the
    /// `+n` on screen, and the secondary people in the strip below.
    let recipients: [Person]
    let receivedAt: Date
    let isUnread: Bool
    let bodyExcerpt: String

    /// Everyone the message touched, sender first.
    var participants: [Person] {
        [sender] + recipients.filter { $0 != sender }
    }

    /// A subject worth showing. Mail hands back an empty string rather than
    /// nothing for a message sent without one.
    var displaySubject: String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no subject)" : trimmed
    }
}
