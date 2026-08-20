import AppKit
import Foundation

/// Why the inbox isn't on screen. Mirrors `CalendarAccessState`: the point
/// of naming the cases apart is that "no messages" and "we were never
/// allowed to look" render identically otherwise, and one of them sends
/// someone hunting for a setting they already answered.
enum MailAccessState: Equatable {
    /// Nothing has been asked yet.
    case pending
    case granted
    /// The Automation prompt was declined, or the switch was turned off
    /// again in System Settings later.
    case denied
    /// Mail is there and permitted, but couldn't answer — it was mid-launch,
    /// or the script timed out against a very large mailbox.
    case unavailable
}

/// Everything one trip to Mail brings back.
struct MailFetch: Equatable {
    var messages: [MailMessage]
    /// Every address configured in Mail, lowercased. This is how "me" gets
    /// left out of the people strip: without it you are the person you
    /// interact with most, on every message you were ever sent.
    var myAddresses: Set<String>
}

/// How an attempt to archive one message ended.
enum MailArchiveResult: Equatable {
    case archived
    /// The message isn't in the mailbox any more — already filed, or moved
    /// in Mail while the column was showing it.
    case notFound
    /// The account has no archive mailbox to file it into. Rare, but real
    /// for a local "On My Mac" mailbox, and the honest answer is to say so
    /// rather than to invent a destination for someone's mail.
    case noArchiveMailbox
    case failed
}

/// How a trip to Mail ended. Not `Result`: the failure here isn't an error
/// anyone catches or rethrows, it's the state the column renders — "you
/// said no" is as ordinary an outcome as a full inbox.
enum MailFetchResult: Equatable {
    case fetched(MailFetch)
    case failed(MailAccessState)
}

/// The only place in the app that talks to Mail.
///
/// Mail's own store (`~/Library/Mail`) needs Full Disk Access to read and
/// is an undocumented format besides, so this asks Mail itself, over Apple
/// Events, with a temporary exception naming that one bundle id — see
/// `Equilibrium.entitlements` for why that trade was made. `NSAppleScript`
/// runs in this process, so the no-subprocess rule still holds.
///
/// Everything is deliberately fetched by **one** script, in as few Apple
/// Events as the dictionary allows: the scalars come back as five plural
/// gets covering every message at once, and only messages recent enough to
/// keep pay for the per-message round trips (recipients, body). The obvious
/// shape — a `repeat` asking each message for each property in turn — is
/// four hundred Apple Events and takes tens of seconds with Mail's window
/// beachballing behind it. Don't simplify it back.
final class MailStore {
    static let shared = MailStore()

    /// How far back the inbox is read, and how much of it. Enough to answer
    /// "what needs doing today" without becoming a mail client.
    static let daysBack = 7
    static let messageLimit = 40
    /// How much of a body the summariser gets. A long thread's useful part
    /// is at the top — the rest is quoted history it has already seen.
    static let bodyCharacterLimit = 1500

    /// How long Mail gets to answer. Generous on purpose: the first Apple
    /// Event after Mail is launched can take the better part of a minute
    /// while it opens its mailboxes, and the whole point of launching it in
    /// the background is not to need it running already.
    static let scriptTimeoutSeconds = 120

    /// Seconds between the local 1970 and the real one — see the script's
    /// comment on why times cross as "seconds since the local 1970".
    /// `secondsFromGMT(for:)` is asked about that instant specifically
    /// rather than today: the UK, for one, was an hour ahead of GMT
    /// through the whole of 1970, and today's offset would put every
    /// message an hour out.
    static var localEpochOffset: Int {
        TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: 0))
    }

    /// NSAppleScript is not thread-safe and must be used from the thread it
    /// built itself on, so it is created and executed only here.
    ///
    /// Serial, so a timer-driven refresh landing on top of a manual one
    /// queues behind it rather than sending Mail two overlapping scripts.
    /// And never the main thread: the first call of all is the one macOS
    /// puts the "Equilibrium wants to control Mail" prompt in front of, and
    /// that prompt needs the main thread to draw itself. Blocking the main
    /// thread waiting for an answer to a question that can't be asked until
    /// the main thread is free is a deadlock, and it presents as the app
    /// hanging on launch with no dialog anywhere.
    private let queue = DispatchQueue(label: "com.alexcollins.Equilibrium.mail", qos: .utility)

    /// Which account to read, or `nil` for Mail's unified inbox.
    ///
    /// Read straight out of UserDefaults rather than cached in a stored
    /// property, because the two sides of it are on different threads: the
    /// picker in preferences writes from the main thread, and every script
    /// this class builds reads on `queue`. A stored property would be a
    /// plain data race, and the visible version of that race is worse than
    /// the theoretical one — a fetch, an archive or a flag would use
    /// whichever value happened to be in the field, which for something
    /// whose entire job is "never read the other mailbox" is the one thing
    /// it must not do. UserDefaults is thread-safe and this is read once
    /// per script, so there is nothing to cache.
    private var selectedAccountID: String? { MailAccountSelectionStore.load() }

    private init() {}

    var selection: String? { selectedAccountID }

    func updateSelection(_ identifier: String?) {
        if let identifier {
            MailAccountSelectionStore.save(identifier)
        } else {
            MailAccountSelectionStore.clear()
        }
    }

    // MARK: - Archiving

    /// Files one message into its account's archive.
    ///
    /// The only thing this app changes in Mail, and it is a move rather
    /// than a delete: the message goes where the Archive button in Mail
    /// itself would put it, and can be found and put back. Nothing here
    /// deletes a message, and nothing sends one.
    func archive(messageID identifier: String) async -> MailArchiveResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.archiveOnQueue(identifier))
            }
        }
    }

    private func archiveOnQueue(_ identifier: String) -> MailArchiveResult {
        guard let script = NSAppleScript(
            source: Self.archiveSource(messageID: identifier, accountID: selectedAccountID)
        ) else {
            return .failed
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else { return .failed }
        switch result.stringValue {
        case "ok": return .archived
        case "notfound": return .notFound
        case "noarchive": return .noArchiveMailbox
        default: return .failed
        }
    }

    /// Flags or unflags a message.
    ///
    /// The Mail-visible half of deferring. The date itself lives in
    /// Reminders (see `RemindersStore`) because Mail's own Remind Me isn't
    /// scriptable; a flag is the only marker Apple Events *can* write that
    /// you'll see when you open Mail, so a message you've put off is at
    /// least distinguishable there from one you haven't looked at.
    ///
    /// It is a blunt instrument, and worth knowing: the flag is Mail's, not
    /// ours, so this will clear a flag you set yourself if you take back a
    /// deferral on a message you'd also flagged.
    @discardableResult
    func setFlagged(messageID identifier: String, flagged: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let script = NSAppleScript(
                    source: Self.flagSource(
                        messageID: identifier,
                        flagged: flagged,
                        accountID: self.selectedAccountID
                    )
                ) else {
                    continuation.resume(returning: false)
                    return
                }
                var errorInfo: NSDictionary?
                let result = script.executeAndReturnError(&errorInfo)
                continuation.resume(returning: errorInfo == nil && result.stringValue == "ok")
            }
        }
    }

    private static func flagSource(messageID: String, flagged: Bool, accountID: String?) -> String {
        """
        on run
            set targetID to "\(escaped(messageID))"
            set accountID to "\(escaped(accountID ?? ""))"

            tell application "Mail"
                with timeout of \(scriptTimeoutSeconds) seconds
                    if accountID is "" then
                        set theBox to inbox
                    else
                        try
                            set theAccount to (first account whose id is accountID)
                            set theBox to mailbox "INBOX" of theAccount
                        on error
                            set theBox to inbox
                        end try
                    end if

                    set matches to (messages of theBox whose message id is targetID)
                    if (count of matches) is 0 then return "notfound"
                    set flagged status of (item 1 of matches) to \(flagged ? "true" : "false")
                    return "ok"
                end timeout
            end tell
        end run
        """
    }

    /// The accounts Mail has configured, for the picker in preferences.
    func accounts() async -> [SelectableMailAccount] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.accountsOnQueue())
            }
        }
    }

    private func accountsOnQueue() -> [SelectableMailAccount] {
        guard let script = NSAppleScript(source: Self.accountsSource) else { return [] }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil, let text = result.stringValue else { return [] }

        return text.components(separatedBy: Self.recordSeparator).compactMap { record in
            let fields = record.components(separatedBy: Self.fieldSeparator)
            guard fields.count >= 4 else { return nil }
            let identifier = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { return nil }
            return SelectableMailAccount(
                id: identifier,
                name: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
                fullName: fields[2].trimmingCharacters(in: .whitespacesAndNewlines),
                addresses: fields[3]
                    .components(separatedBy: Self.listSeparator)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.contains("@") }
            )
        }
    }

    // MARK: - Fetch

    /// Reads the inbox, or explains why it couldn't.
    ///
    /// Sending an Apple Event to Mail launches it if it isn't running —
    /// deliberately, so the column is populated whether or not you keep Mail
    /// open. macOS launches it in the background; it doesn't come to the
    /// front and steal what you were doing.
    func fetch() async -> MailFetchResult {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.fetchOnQueue())
            }
        }
    }

    private func fetchOnQueue() -> MailFetchResult {
        dispatchPrecondition(condition: .onQueue(queue))

        // Compiled per fetch rather than cached, because the cutoff is
        // written into the source: "now" can't be asked for in AppleScript
        // (see the script's comment on scripting additions), so it arrives
        // as a literal, and a literal that moves is a different script.
        // Compiling a few kilobytes costs a millisecond or two against a
        // fetch measured in seconds.
        let cutoff = Int(Date().timeIntervalSince1970)
            - Self.daysBack * 24 * 60 * 60
            + Self.localEpochOffset
        guard let script = NSAppleScript(
            source: Self.source(cutoff: cutoff, accountID: selectedAccountID)
        ) else {
            return .failed(.unavailable)
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            return .failed(Self.state(forScriptError: errorInfo))
        }
        guard let text = result.stringValue else { return .failed(.unavailable) }
        return .fetched(Self.parse(text))
    }

    /// Turns an AppleScript error into something the column can say.
    ///
    /// The number matters more than the message: Apple's own text for
    /// -1743 is "Not authorized to send Apple events to Mail", which is
    /// true and tells nobody where the switch is.
    private static func state(forScriptError info: NSDictionary) -> MailAccessState {
        let number = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        switch number {
        // errAEEventNotPermitted, and the "would require consent" variant
        // returned when the prompt is suppressed rather than answered.
        case -1743, -1744:
            return .denied
        default:
            // Mail missing, mid-launch, or the script timing out against a
            // very large mailbox. All of them mean "no inbox this time,
            // try again on the next tick".
            return .unavailable
        }
    }

    // MARK: - Parsing

    /// The three separators the script builds its answer with. Control
    /// characters, because every printable candidate turns up in real
    /// subjects and real display names.
    private static let recordSeparator = "\u{1E}"
    private static let fieldSeparator = "\u{1F}"
    private static let listSeparator = "\u{1D}"

    /// Fields per message record, in the order the script writes them.
    /// The body is last so that a body somehow containing a separator adds
    /// trailing fields that can be folded back into it rather than
    /// shifting every other field along by one.
    private enum Field: Int, CaseIterable {
        case id, subject, sender, stamp, readStatus
        case toAddresses, toNames, ccAddresses, ccNames, body
    }

    static func parse(_ text: String) -> MailFetch {
        var records = text.components(separatedBy: recordSeparator)
        guard !records.isEmpty else { return MailFetch(messages: [], myAddresses: []) }

        // The first record is the account addresses, not a message.
        let myAddresses = Set(
            records.removeFirst()
                .components(separatedBy: listSeparator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { $0.contains("@") }
        )

        let messages = records.compactMap { parseMessage($0, myAddresses: myAddresses) }
        return MailFetch(
            messages: messages.sorted { $0.receivedAt > $1.receivedAt },
            myAddresses: myAddresses
        )
    }

    private static func parseMessage(_ record: String, myAddresses: Set<String>) -> MailMessage? {
        let fields = record.components(separatedBy: fieldSeparator)
        guard fields.count >= Field.allCases.count else { return nil }

        let identifier = fields[Field.id.rawValue].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }
        guard let sender = Person.parse(fields[Field.sender.rawValue]) else { return nil }

        // Seconds since the local 1970, shifted back onto the real one.
        let stamp = Double(fields[Field.stamp.rawValue].trimmingCharacters(in: .whitespacesAndNewlines))
        guard let stamp else { return nil }
        let receivedAt = Date(timeIntervalSince1970: stamp - Double(localEpochOffset))

        let recipients = people(
            addresses: fields[Field.toAddresses.rawValue],
            names: fields[Field.toNames.rawValue]
        ) + people(
            addresses: fields[Field.ccAddresses.rawValue],
            names: fields[Field.ccNames.rawValue]
        )

        // Anything past the last expected field belongs to the body: see
        // `Field`.
        let body = fields[Field.body.rawValue...].joined(separator: fieldSeparator)

        return MailMessage(
            id: identifier,
            subject: fields[Field.subject.rawValue],
            sender: sender,
            recipients: dedupe(recipients).filter { !myAddresses.contains($0.address) && $0 != sender },
            receivedAt: receivedAt,
            isUnread: fields[Field.readStatus.rawValue].trimmingCharacters(in: .whitespacesAndNewlines) == "false",
            bodyExcerpt: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Zips the two lists the script writes for one header. They're written
    /// separately, and padded, precisely so they stay index-aligned: a
    /// display name containing the list separator would break the pairing,
    /// which is why that separator is a control character.
    private static func people(addresses: String, names: String) -> [Person] {
        let addressList = addresses.components(separatedBy: listSeparator)
        let nameList = names.components(separatedBy: listSeparator)
        return addressList.enumerated().compactMap { index, address in
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("@") else { return nil }
            let name = index < nameList.count ? nameList[index] : nil
            return Person(address: trimmed, name: name)
        }
    }

    /// One entry per person, keeping whichever copy carried a display name.
    private static func dedupe(_ people: [Person]) -> [Person] {
        var seen: [Person] = []
        for person in people {
            if let index = seen.firstIndex(of: person) {
                seen[index] = seen[index].mergingDisplayName(with: person)
            } else {
                seen.append(person)
            }
        }
        return seen
    }

    // MARK: - The script

    /// One trip to Mail, in AppleScript.
    ///
    /// Shape worth understanding before editing:
    ///
    /// - The five scalar properties are **plural gets** — `subject of
    ///   messages 1 thru 40 of inbox` is one Apple Event returning forty
    ///   subjects. Asking each message in turn is forty events per property.
    /// - Only messages inside the cutoff pay for the per-message gets
    ///   (recipients and body), so a quiet week costs almost nothing.
    /// - Everything is coerced through `joinList`, which turns `missing
    ///   value` into an empty string. A message with no Message-ID header,
    ///   no display name on a recipient, or a body Mail hasn't downloaded is
    ///   ordinary, and any one of them aborts a plain concatenation.
    /// - **No `current date`, and no other scripting addition.** Standard
    ///   Additions is an `.osax`, and the App Sandbox refuses to load
    ///   scripting additions at all; inside a `tell application "Mail"`
    ///   block the unresolved command goes to Mail instead, which never
    ///   answers it, and the whole script dies on `AppleEvent timed out`
    ///   (-1712) before reading a single message. "Now" is therefore
    ///   computed in Swift and interpolated in as a plain number.
    /// - Times cross the boundary as **seconds since the local 1970**: a
    ///   reference date is made by copying a real message date and setting
    ///   its fields, which needs no addition, and `Self.localEpochOffset`
    ///   undoes the time-zone shift on the Swift side. The alternative —
    ///   an AppleScript date coerced to text — is locale-dependent and
    ///   unparseable on a Mac set to a format we didn't anticipate.
    /// Quotes a value for use inside an AppleScript string literal. Account
    /// ids are Mail's own and contain nothing exotic, but they are still
    /// data being pasted into source, and the one place that must never be
    /// assumed is the one nobody checks.
    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func source(cutoff: Int, accountID: String?) -> String {
        """
    on joinList(theList, sep)
        if class of theList is not list then set theList to {theList}
        set out to ""
        set total to count of theList
        repeat with i from 1 to total
            set v to item i of theList
            if v is missing value then set v to ""
            if i > 1 then set out to out & sep
            try
                set out to out & (v as text)
            end try
        end repeat
        return out
    end joinList

    on asList(v)
        if class of v is list then return v
        return {v}
    end asList

    on run
        set fieldSep to (character id 31)
        set recordSep to (character id 30)
        set listSep to (character id 29)
        set cutoff to \(cutoff)
        set accountID to "\(escaped(accountID ?? ""))"
        set maxMessages to \(messageLimit)
        set bodyLimit to \(bodyCharacterLimit)

        tell application "Mail"
            with timeout of \(scriptTimeoutSeconds) seconds
                -- The chosen account's own inbox, or Mail's unified one when
                -- nothing has been chosen. Scoping here rather than
                -- filtering afterwards is the whole privacy claim: a
                -- personal account that isn't selected is never read.
                if accountID is "" then
                    set theBox to inbox
                else
                    try
                        set theAccount to (first account whose id is accountID)
                        set theBox to mailbox "INBOX" of theAccount
                    on error
                        -- An account whose inbox isn't called INBOX, or one
                        -- that has been removed since it was picked. The
                        -- unified inbox is wrong but visible, which beats an
                        -- empty column with no explanation.
                        set theBox to inbox
                    end try
                end if

                set myAddresses to {}
                repeat with anAccount in every account
                    try
                        set myAddresses to myAddresses & (email addresses of anAccount)
                    end try
                end repeat
                set out to my joinList(myAddresses, listSep)

                set total to (count of messages of theBox)
                if total > maxMessages then set total to maxMessages
                if total is 0 then return out

                -- The plural get has to be applied to the *specifier*, not
                -- to a variable holding it: assigning `messages 1 thru n of
                -- inbox` resolves it into a plain list of references, and
                -- `message id of <list>` is not a thing Mail can answer
                -- (-1728, "Can't get message id of {...}"). So the range is
                -- written out again for each property — still one Apple
                -- Event each, covering every message.
                set theMessages to my asList(messages 1 thru total of theBox)
                set theIds to my asList(message id of (messages 1 thru total of theBox))
                set theSubjects to my asList(subject of (messages 1 thru total of theBox))
                set theSenders to my asList(sender of (messages 1 thru total of theBox))
                set theDates to my asList(date received of (messages 1 thru total of theBox))
                set theReads to my asList(read status of (messages 1 thru total of theBox))

                -- The reference instant, built by mutating a copy of a real
                -- message date. `date "1 January 1970"` would parse a string
                -- against whatever format this Mac is set to.
                copy (item 1 of theDates) to epochDate
                set year of epochDate to 1970
                set month of epochDate to January
                set day of epochDate to 1
                set time of epochDate to 0

                repeat with i from 1 to total
                    set stamp to (((item i of theDates) - epochDate) div 1)
                    if stamp is greater than or equal to cutoff then
                        set aMessage to item i of theMessages

                        set toAddresses to ""
                        set toNames to ""
                        set ccAddresses to ""
                        set ccNames to ""
                        try
                            set toAddresses to my joinList(address of to recipients of aMessage, listSep)
                            set toNames to my joinList(name of to recipients of aMessage, listSep)
                        end try
                        try
                            set ccAddresses to my joinList(address of cc recipients of aMessage, listSep)
                            set ccNames to my joinList(name of cc recipients of aMessage, listSep)
                        end try

                        set theBody to ""
                        try
                            set theBody to content of aMessage
                            if (count of theBody) > bodyLimit then set theBody to text 1 thru bodyLimit of theBody
                        end try

                        set theRecord to {item i of theIds, item i of theSubjects, item i of theSenders, stamp as text, (item i of theReads) as text, toAddresses, toNames, ccAddresses, ccNames, theBody}
                        set out to out & recordSep & my joinList(theRecord, fieldSep)
                    end if
                end repeat
            end timeout
        end tell
        return out
    end run
    """
    }

    /// Moves one message to its account's archive mailbox.
    ///
    /// Mail's dictionary has no `archive` command — the Archive button in
    /// Mail is a move, and so is this: a message's `mailbox` property is
    /// writable, and setting it files the message there.
    ///
    /// The mailbox is looked for by name because there's nothing else to go
    /// on. "Archive" is what Mail creates and what IMAP servers advertise;
    /// "All Mail" is Gmail's, for accounts set up without an archive folder
    /// of their own. If neither is there the message is left exactly where
    /// it was, and the column says so.
    private static func archiveSource(messageID: String, accountID: String?) -> String {
        """
        on run
            set targetID to "\(escaped(messageID))"
            set accountID to "\(escaped(accountID ?? ""))"

            tell application "Mail"
                with timeout of \(scriptTimeoutSeconds) seconds
                    if accountID is "" then
                        set theBox to inbox
                    else
                        try
                            set theAccount to (first account whose id is accountID)
                            set theBox to mailbox "INBOX" of theAccount
                        on error
                            set theBox to inbox
                        end try
                    end if

                    set matches to (messages of theBox whose message id is targetID)
                    if (count of matches) is 0 then return "notfound"
                    set theMessage to item 1 of matches

                    set owner to missing value
                    try
                        set owner to account of (mailbox of theMessage)
                    end try
                    if owner is missing value then return "noarchive"

                    set theArchive to missing value
                    try
                        set theArchive to mailbox "Archive" of owner
                    end try
                    if theArchive is missing value then
                        try
                            set theArchive to mailbox "All Mail" of owner
                        end try
                    end if
                    if theArchive is missing value then return "noarchive"

                    set mailbox of theMessage to theArchive
                    return "ok"
                end timeout
            end tell
        end run
        """
    }

    /// The accounts, for the picker. Separate and tiny, so opening
    /// preferences doesn't drag the whole inbox across with it.
    private static let accountsSource = """
    on joinList(theList, sep)
        if class of theList is not list then set theList to {theList}
        set out to ""
        set total to count of theList
        repeat with i from 1 to total
            set v to item i of theList
            if v is missing value then set v to ""
            if i > 1 then set out to out & sep
            try
                set out to out & (v as text)
            end try
        end repeat
        return out
    end joinList

    on run
        set fieldSep to (character id 31)
        set recordSep to (character id 30)
        set listSep to (character id 29)
        set out to ""
        tell application "Mail"
            with timeout of 60 seconds
                repeat with anAccount in every account
                    try
                        if enabled of anAccount then
                            set out to out & recordSep & (id of anAccount) & fieldSep & (name of anAccount) & fieldSep & (full name of anAccount) & fieldSep & my joinList(email addresses of anAccount, listSep)
                        end if
                    end try
                end repeat
            end timeout
        end tell
        return out
    end run
    """
}
