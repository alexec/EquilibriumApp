import SwiftUI

/// Lets the user choose which calendars Equilibrium reads, grouped by the
/// account each belongs to.
///
/// The point is privacy: someone with work and personal calendars on the
/// same Mac can keep the personal ones out of the app entirely. Deselecting
/// a calendar isn't cosmetic — it drops out of the EventKit query, so its
/// events are never read at all.
struct CalendarPickerView: View {
    /// All selectable calendars, already sorted by account then title.
    let calendars: [SelectableCalendar]
    /// Currently selected identifiers, or `nil` when the user hasn't
    /// narrowed the selection and every calendar is being read.
    let selection: Set<String>?
    let onChange: (Set<String>?) -> Void

    /// `nil` selection means "all" — resolve it for display so every row
    /// starts checked.
    private var effectiveSelection: Set<String> {
        selection ?? Set(calendars.map(\.id))
    }

    private var groups: [(source: String, calendars: [SelectableCalendar])] {
        var order: [String] = []
        var bySource: [String: [SelectableCalendar]] = [:]
        for calendar in calendars {
            if bySource[calendar.sourceTitle] == nil { order.append(calendar.sourceTitle) }
            bySource[calendar.sourceTitle, default: []].append(calendar)
        }
        return order.map { ($0, bySource[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Calendars to read")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if selection != nil {
                    Button("All") { onChange(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
                }
            }

            if calendars.isEmpty {
                Text("No calendars available.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groups, id: \.source) { group in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.source)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                ForEach(group.calendars) { calendar in
                                    row(for: calendar)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)

                if effectiveSelection.isEmpty {
                    Text("No calendars selected — meeting time won't be tracked.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(for calendar: SelectableCalendar) -> some View {
        Toggle(isOn: Binding(
            get: { effectiveSelection.contains(calendar.id) },
            set: { isOn in
                var updated = effectiveSelection
                if isOn { updated.insert(calendar.id) } else { updated.remove(calendar.id) }
                // Always hand back an explicit set, even when everything is
                // ticked: that records "the user checked this and was happy",
                // so a calendar added later isn't silently pulled in.
                onChange(updated)
            }
        )) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color(for: calendar))
                    .frame(width: 7, height: 7)
                Text(calendar.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .toggleStyle(.checkbox)
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
