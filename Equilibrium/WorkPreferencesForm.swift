import SwiftUI

/// A plain set of controls for `WorkPreferences` — the way you configure
/// your week on the many Macs that can't run the on-device LLM (see
/// `OnDeviceModel`), where `PreferencesView`'s "describe your ideal week"
/// text box has nothing to parse it with.
///
/// Every field the LLM can fill in has a control here, so the two paths
/// produce exactly the same `WorkPreferences` — nothing is reachable only
/// by describing it in words.
struct WorkPreferencesForm: View {
    @Binding var preferences: WorkPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Hours a week") {
                HStack(spacing: 6) {
                    Text(HoursFormat.string(preferences.weeklyTargetHours))
                        .font(.system(size: 12).monospacedDigit())
                    Stepper("", value: $preferences.weeklyTargetHours, in: WorkPreferences.weeklyTargetRange, step: 1)
                        .labelsHidden()
                }
            }

            ForEach(Array(preferences.shifts.enumerated()), id: \.element.id) { index, shift in
                row(shift.slot.label) {
                    HStack(spacing: 4) {
                        hourPicker(selection: startHour(at: index), range: 0..<24)
                        Text("to").font(.system(size: 12)).foregroundColor(.secondary)
                        hourPicker(selection: endHour(at: index), range: 1..<25)
                    }
                }
            }

            row("Meetings/day") {
                optionalHoursPicker(selection: $preferences.targetMeetingHoursPerDay)
            }

            row("Focus/day") {
                optionalHoursPicker(selection: $preferences.targetFocusHoursPerDay)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 88, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func hourPicker(selection: Binding<Double>, range: Range<Int>) -> some View {
        Picker("", selection: selection) {
            ForEach(range, id: \.self) { hour in
                Text(WorkPreferences.clockLabel(Double(hour))).tag(Double(hour))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func optionalHoursPicker(selection: Binding<Double?>) -> some View {
        Picker("", selection: selection) {
            Text("Not set").tag(Double?.none)
            ForEach(WorkPreferences.dailyHoursOptions, id: \.self) { hours in
                Text(HoursFormat.string(hours)).tag(Double?.some(hours))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Start and end are edited through bindings that keep each shift at
    /// least an hour long, rather than letting the two pickers cross over
    /// into an end-before-start slot that nothing downstream can draw.
    private func startHour(at index: Int) -> Binding<Double> {
        Binding(
            get: { preferences.shifts[index].startHour },
            set: { newValue in
                preferences.shifts[index].startHour = newValue
                if preferences.shifts[index].endHour <= newValue {
                    preferences.shifts[index].endHour = min(newValue + 1, 24)
                }
            }
        )
    }

    private func endHour(at index: Int) -> Binding<Double> {
        Binding(
            get: { preferences.shifts[index].endHour },
            set: { newValue in
                preferences.shifts[index].endHour = newValue
                if preferences.shifts[index].startHour >= newValue {
                    preferences.shifts[index].startHour = max(newValue - 1, 0)
                }
            }
        )
    }
}
