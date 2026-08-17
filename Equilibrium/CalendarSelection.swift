import Foundation

/// Persists which calendar the user wants Equilibrium to read.
///
/// Deliberately stored separately from `WorkPreferences` rather than as
/// another field on it: `WorkPreferencesGenerator` builds a *fresh*
/// `WorkPreferences` from the user's free-text description, so a calendar
/// selection living there would be silently wiped every time someone
/// re-described their week.
///
/// A single calendar, not a set: work lives on one calendar for almost
/// everyone, and picking one is a clearer question to answer than ticking
/// through a list. `nil` means the user hasn't chosen yet, in which case
/// every calendar is read so the chart still populates on first run.
enum CalendarSelectionStore {
    private static let key = "CalendarSelection.identifier"

    /// The chosen calendar identifier, or `nil` if the user has never
    /// picked one.
    static func load(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    static func save(_ identifier: String, defaults: UserDefaults = .standard) {
        defaults.set(identifier, forKey: key)
    }

    /// Drops the explicit choice, reverting to "read every calendar".
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
    /// The owning account, e.g. "iCloud", "Google", "Exchange" — shown
    /// alongside the name so two calendars both called "Calendar" are
    /// distinguishable.
    let sourceTitle: String
    /// The calendar's colour, for the swatch beside its name.
    let colorComponents: [Double]?
}
