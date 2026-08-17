import Foundation

/// Persists which calendars the user wants Equilibrium to read.
///
/// Deliberately stored separately from `WorkPreferences` rather than as
/// another field on it: `WorkPreferencesGenerator` builds a *fresh*
/// `WorkPreferences` from the user's free-text description, so a calendar
/// selection living there would be silently wiped every time someone
/// re-described their week.
///
/// `nil` and "selected everything" are different states on purpose:
///
/// - `nil` — the user has never opened the picker. Every calendar is read,
///   which keeps the chart populated on first run.
/// - a set — the user has made an explicit choice, and *only* those
///   calendars are read. An empty set therefore means "read nothing",
///   not "read everything"; without that distinction, deselecting your
///   last calendar would silently re-enable all of them.
enum CalendarSelectionStore {
    private static let key = "CalendarSelection.identifiers"

    /// Returns the chosen calendar identifiers, or `nil` if the user has
    /// never narrowed the selection.
    static func load(defaults: UserDefaults = .standard) -> Set<String>? {
        guard let stored = defaults.array(forKey: key) as? [String] else { return nil }
        return Set(stored)
    }

    static func save(_ identifiers: Set<String>, defaults: UserDefaults = .standard) {
        defaults.set(Array(identifiers), forKey: key)
    }

    /// Drops the explicit selection, reverting to "read every calendar".
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// A calendar the user can pick in preferences — a plain value type so the
/// UI never has to hold a live `EKCalendar` (which is tied to the
/// `EKEventStore` that vended it).
struct SelectableCalendar: Identifiable, Hashable {
    /// The `EKCalendar.calendarIdentifier`.
    let id: String
    let title: String
    /// The owning account, e.g. "iCloud", "Google", "Exchange" — shown as a
    /// section header so two calendars both called "Calendar" are
    /// distinguishable.
    let sourceTitle: String
    /// The calendar's colour, for the swatch beside its name.
    let colorComponents: [Double]?
}
