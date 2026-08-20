import Foundation

/// Persists which Mail account Equilibrium reads.
///
/// Stored in UserDefaults beside `CalendarSelectionStore` and for the same
/// reason it isn't a field on `WorkPreferences`: that type is rebuilt from
/// scratch by `WorkPreferencesGenerator` whenever someone re-describes
/// their week, which would silently wipe the choice.
///
/// The privacy argument is stronger here than for calendars. Most people
/// have a work account and a personal one in the same Mail, and pointing
/// the app at work means the personal mailbox is never read — not filtered
/// after the fact, but never asked for: the account is written into the
/// AppleScript's own scope, so those messages don't cross into the app at
/// all. `nil` means no choice has been made, in which case Mail's unified
/// inbox is read so the column populates on first run.
enum MailAccountSelectionStore {
    private static let key = "MailAccountSelection.identifier"

    static func load(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    static func save(_ identifier: String, defaults: UserDefaults = .standard) {
        defaults.set(identifier, forKey: key)
    }

    /// Drops the explicit choice, reverting to the unified inbox.
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// A Mail account the user can pick in preferences — a plain value type,
/// like `SelectableCalendar`, so the UI never holds anything belonging to
/// Mail.
struct SelectableMailAccount: Identifiable, Hashable {
    /// Mail's own account id. Used in preference to the name, which people
    /// rename — a selection stored by name silently stops matching.
    let id: String
    let name: String
    /// The name you send mail under. Used to recognise yourself in a
    /// meeting's attendee list, where you appear by name at an address
    /// nothing else knows is yours — see `PeopleDirectory.isSelf`.
    let fullName: String
    /// The addresses on the account, shown under the name so two accounts
    /// both called "Work" are still distinguishable.
    let addresses: [String]

    var addressSummary: String {
        addresses.first ?? ""
    }
}
