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

    /// Offered as meeting/focus targets: half-hour steps, since that's the
    /// resolution `HoursFormat` displays anyway.
    private static let dailyHourOptions: [Double] = Array(stride(from: 0.5, through: 8.0, by: 0.5))

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Hours a week") {
                HStack(spacing: 6) {
                    Text(HoursFormat.string(preferences.weeklyTargetHours))
                        .font(.system(size: 12).monospacedDigit())
                    Stepper("", value: $preferences.weeklyTargetHours, in: 5...80, step: 1)
                        .labelsHidden()
                }
            }

            row("Workday") {
                HStack(spacing: 4) {
                    hourPicker(selection: startHour, range: 0..<24)
                    Text("to").font(.system(size: 12)).foregroundColor(.secondary)
                    hourPicker(selection: endHour, range: 1..<25)
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
            ForEach(Self.dailyHourOptions, id: \.self) { hours in
                Text(HoursFormat.string(hours)).tag(Double?.some(hours))
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Start and end are edited through bindings that keep the workday at
    /// least an hour long, rather than letting the two pickers cross over
    /// into an end-before-start span that nothing downstream can draw.
    private var startHour: Binding<Double> {
        Binding(
            get: { preferences.workdayStartHour },
            set: { newValue in
                preferences.workdayStartHour = newValue
                if preferences.workdayEndHour <= newValue {
                    preferences.workdayEndHour = newValue + 1
                }
            }
        )
    }

    private var endHour: Binding<Double> {
        Binding(
            get: { preferences.workdayEndHour },
            set: { newValue in
                preferences.workdayEndHour = newValue
                if preferences.workdayStartHour >= newValue {
                    preferences.workdayStartHour = newValue - 1
                }
            }
        )
    }
}
