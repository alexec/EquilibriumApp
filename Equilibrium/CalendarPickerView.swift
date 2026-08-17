import SwiftUI

/// Lets the user pick the one calendar Equilibrium reads.
///
/// The point is privacy: someone with work and personal calendars on the
/// same Mac can point the app at work and leave the rest untouched. The
/// choice isn't cosmetic — every other calendar drops out of the EventKit
/// query, so their events are never read at all.
///
/// A single choice rather than a set of checkboxes: work lives on one
/// calendar for almost everyone. "All calendars" stays available as the
/// unset default, so the chart still populates before anyone visits
/// preferences.
struct CalendarPickerView: View {
    /// All selectable calendars, already sorted by account then title.
    let calendars: [SelectableCalendar]
    /// The chosen calendar, or `nil` when every calendar is being read.
    let selection: String?
    let onChange: (String?) -> Void

    /// Sentinel for the "All calendars" row, which represents a `nil`
    /// selection. `Picker` needs every tag to be the same type, so the
    /// absence of a choice has to be spelled as a value.
    private static let allTag = ""

    /// True when a calendar was picked but no longer exists — deleted or
    /// unsubscribed since. Worth calling out, because the app reads nothing
    /// in that state rather than quietly reverting to reading everything.
    private var selectionIsMissing: Bool {
        guard let selection else { return false }
        return !calendars.contains { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calendar to read")
                .font(.system(size: 12, weight: .medium))

            if calendars.isEmpty {
                Text("No calendars available.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Picker("", selection: Binding(
                    get: { selection ?? Self.allTag },
                    set: { onChange($0 == Self.allTag ? nil : $0) }
                )) {
                    Text("All calendars").tag(Self.allTag)
                    ForEach(calendars) { calendar in
                        row(for: calendar).tag(calendar.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                if selectionIsMissing {
                    Text("That calendar is no longer available — nothing is being read.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Account name is included inline rather than as a section header:
    /// menu-style pickers show only the selected row when closed, so the
    /// account has to travel with the title to stay useful there.
    private func row(for calendar: SelectableCalendar) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color(for: calendar))
                .frame(width: 7, height: 7)
            Text("\(calendar.title) — \(calendar.sourceTitle)")
        }
    }

    private func color(for calendar: SelectableCalendar) -> Color {
        guard let components = calendar.colorComponents, components.count >= 3 else {
            return .secondary
        }
        return Color(
            .sRGB,
            red: components[0],
            green: components[1],
            blue: components[2],
            opacity: 1
        )
    }
}
