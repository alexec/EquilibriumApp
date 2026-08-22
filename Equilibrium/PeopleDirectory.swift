import Foundation

/// One person, and why they're in your day.
struct PersonActivity: Identifiable, Equatable {
    let person: Person
    /// Whether they asked something of you, as opposed to merely being in
    /// the room. See `PeopleDirectory`.
    let isPrimary: Bool
    let messageCount: Int
    let meetingCount: Int
    /// The most recent thing they were part of, for ordering.
    let latest: Date

    var id: String { person.id }

    /// How much of your week this person accounts for. The ordering key:
    /// the people who have asked you for the most are the ones worth
    /// seeing first.
    var weight: Int { messageCount + meetingCount }

    /// "2 emails · 1 meeting" — why this chip is here, in the fewest words.
    var reason: String {
        var parts: [String] = []
        if messageCount > 0 {
            parts.append("\(messageCount) email\(messageCount == 1 ? "" : "s")")
        }
        if meetingCount > 0 {
            parts.append("\(meetingCount) meeting\(meetingCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

/// Who you're working with at the moment, drawn from the inbox and the
/// diary together.
///
/// The split that matters is **primary against secondary**, and it isn't
/// about seniority or how well you know someone — it's about direction. A
/// person is primary when something came *from* them to *you*: they sent
/// the message, or they called the meeting. They are secondary when they
/// were merely on the same message or in the same room. The first group is
/// who your day is answerable to; the second is context.
///
/// The split decides how a chip is *drawn*, not where it sits: the list is
/// ordered by how much of your week someone accounts for, and primary only
/// breaks a tie between two people with the same total. See the sort.
///
/// Two consequences worth stating, because they're the whole rule:
///
/// - **Sending once is enough.** Someone who wrote to you on Monday and was
///   copied on four things since is primary, not demoted to context by the
///   four. Only a person who has never once been the sender or the
///   organiser stays secondary.
/// - **Every appearance counts towards the total.** Sending and being
///   copied in both add one, so the person who wrote twice and was cc'd
///   twice sits above the person who wrote twice — the ordering is how much
///   of your week they account for, not how much of it they initiated.
///
/// Pure and free of I/O, like `MeetingCalculator` and `WorkloadRecommender`,
/// so the rule can be reasoned about on its own.
enum PeopleDirectory {
    /// Whether this is you.
    ///
    /// The addresses we're sure about come from Mail's accounts and from
    /// attendees the calendar flagged as the current user. Neither catches
    /// every case: people are invited at addresses they don't collect mail
    /// for, and an invitation that arrived through a forwarding address, or
    /// from a directory that spells you differently, isn't always matched
    /// to you by EventKit at all. What turns up in the strip then is
    /// yourself, listed as the colleague you see most.
    ///
    /// So the local part is compared too — `alex.e.c@work.com` against
    /// `alex.e.c@me.com` — but only when it's distinctive enough to mean
    /// something. A shared local part is decent evidence when it's
    /// `alex.e.c` and none at all when it's `alex`, `info` or `hello`,
    /// which is why `distinctiveLocalParts` throws the short and undotted
    /// ones away rather than hiding a real person who happens to share
    /// your first name.
    static func isSelf(
        _ person: Person,
        addresses: Set<String>,
        localParts: Set<String>,
        names: Set<String> = []
    ) -> Bool {
        if addresses.contains(person.address) { return true }
        if let localPart = person.address.split(separator: "@").first,
           localParts.contains(String(localPart)) {
            return true
        }
        return !names.isEmpty && person.name.map { names.contains(normalizedName($0)) } == true
    }

    /// A name reduced to its parts, in a fixed order, so that "Collins,
    /// Alex" from a corporate directory and "Alex Collins" from a mail
    /// account are recognised as the same name. Sorting the words is what
    /// makes the comparison survive the reversal; case and punctuation go
    /// for the same reason.
    static func normalizedName(_ name: String) -> String {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .sorted()
            .joined(separator: " ")
    }

    /// The local parts worth matching on: long enough, or separated, that
    /// two people sharing one is unlikely.
    static func distinctiveLocalParts(of addresses: Set<String>) -> Set<String> {
        Set(
            addresses.compactMap { address -> String? in
                guard let localPart = address.split(separator: "@").first else { return nil }
                let text = String(localPart)
                let separated = text.contains(".") || text.contains("_")
                guard separated || text.count >= 8 else { return nil }
                return text
            }
        )
    }

    static func people(
        messages: [MailMessage],
        meetings: [DayMeeting],
        myAddresses: Set<String>,
        myNames: Set<String> = []
    ) -> [PersonActivity] {
        /// Accumulated per address, since one person turns up as a sender
        /// on Monday and a cc on Tuesday and is one chip either way.
        struct Tally {
            var person: Person
            var isPrimary = false
            var messageCount = 0
            var meetingCount = 0
            var latest = Date.distantPast
        }
        var tallies: [String: Tally] = [:]

        let selfLocalParts = distinctiveLocalParts(of: myAddresses)
        let selfNames = Set(myNames.map(normalizedName)).filter { !$0.isEmpty }

        func record(
            _ person: Person,
            primary: Bool,
            at date: Date,
            message: Int = 0,
            meeting: Int = 0
        ) {
            // You are in every message you were sent and every meeting you
            // attend, so without this you are the person you work with most.
            guard !isSelf(
                person,
                addresses: myAddresses,
                localParts: selfLocalParts,
                names: selfNames
            ) else { return }

            var tally = tallies[person.address] ?? Tally(person: person)
            // Whichever record carries a display name wins; a cc line often
            // has only an address where the From line had a name.
            tally.person = tally.person.mergingDisplayName(with: person)
            // Primary anywhere in the day is primary: someone who sent you a
            // message this morning isn't demoted by also being copied on
            // somebody else's this afternoon.
            tally.isPrimary = tally.isPrimary || primary
            tally.messageCount += message
            tally.meetingCount += meeting
            tally.latest = max(tally.latest, date)
            tallies[person.address] = tally
        }

        for message in messages {
            record(message.sender, primary: true, at: message.receivedAt, message: 1)
            for recipient in message.recipients {
                record(recipient, primary: false, at: message.receivedAt, message: 1)
            }
        }

        for meeting in meetings {
            if let organizer = meeting.organizer {
                record(organizer, primary: true, at: meeting.start, meeting: 1)
            }
            for participant in meeting.participants {
                record(participant, primary: false, at: meeting.start, meeting: 1)
            }
        }

        return tallies.values
            .map {
                PersonActivity(
                    person: $0.person,
                    isPrimary: $0.isPrimary,
                    messageCount: $0.messageCount,
                    meetingCount: $0.meetingCount,
                    latest: $0.latest
                )
            }
            // Whoever accounts for the most of your week first, then
            // primary over secondary, then most recent, then the address.
            //
            // Ordering by recency alone put whoever happened to write last
            // at the front, which is a fact about the clock rather than
            // about the week: the person who has sent four messages and
            // called two meetings is the one the day is really about, and
            // they belong at the top even if they wrote on Monday.
            //
            // Weight leads and `isPrimary` is only a tie-break, which is a
            // reversal of the first version. Sorting on the flag first
            // sounded right — the people who asked something of you before
            // the people who were merely there — but on a diary-heavy week
            // it makes the strip look like it isn't sorted at all: every
            // meeting has an organiser, so a long run of primaries counts
            // down 4, 3, 2, 1, 1, 1 and then the secondaries start again at
            // 9. Two orderings end to end read as none, and the counts are
            // printed on every chip, so the jump back up is right there to
            // be seen. The distinction hasn't gone anywhere — it is what
            // draws a chip solid rather than light — it just no longer
            // splits the list into two blocks.
            //
            // The address is the last resort and exists only to be
            // deterministic. Everyone in one meeting shares a `latest` (the
            // meeting's start) and usually a weight of 1, so without it
            // they came out in `tallies`' hash order, which Swift seeds per
            // process: the same week ordered differently on two Macs, and
            // differently again after a relaunch.
            .sorted { left, right in
                if left.weight != right.weight { return left.weight > right.weight }
                if left.isPrimary != right.isPrimary { return left.isPrimary }
                if left.latest != right.latest { return left.latest > right.latest }
                return left.person.address < right.person.address
            }
    }
}
