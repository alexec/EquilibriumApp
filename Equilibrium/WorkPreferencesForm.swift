import SwiftUI

/// A plain set of controls for `WorkPreferences` — the way you configure
/// your week on the many Macs that can't run the on-device LLM (see
/// `OnDeviceModel`), where `PreferencesView`'s "describe your ideal week"
/// text box has nothing to parse it with.
///
/// Every field the LLM can fill in has a control here, so the two paths
/// produce exactly the same `WorkPreferences` — nothing is reachable only
/// by describing it in words. That's why all three slots get a row even
/// when the schedule has fewer: a migrated short day, or one the model
/// answered badly enough that a slot was dropped, would otherwise leave
/// that slot with nowhere to be set and no way back.
struct WorkPreferencesForm: View {
    @Binding var preferences: WorkPreferences

    /// The label column, shared by the plain rows and the slot checkboxes
    /// so every control in the form starts at the same x.
    private static let labelWidth: CGFloat = 84

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

            ForEach(ShiftTemplate.Slot.allCases, id: \.self) { slot in
                shiftRow(slot)
            }

            row("Meetings/day") {
                optionalHoursPicker(selection: $preferences.targetMeetingHoursPerDay)
            }

            row("Focus/day") {
                optionalHoursPicker(selection: $preferences.targetFocusHoursPerDay)
            }
        }
    }

    /// The slot's own checkbox stands in for the label, so a row that can be
    /// switched off costs no more width than one that can't — this popover
    /// has 300pt to work with and two hour pickers already in it.
    private func shiftRow(_ slot: ShiftTemplate.Slot) -> some View {
        let isWorked = preferences.shifts.contains { $0.slot == slot }
        return HStack(spacing: 8) {
            Toggle(isOn: worked(slot)) {
                Text(slot.label).font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            .frame(width: Self.labelWidth, alignment: .leading)

            HStack(spacing: 4) {
                hourPicker(selection: startHour(slot), range: 0..<24)
                // Fixed, or SwiftUI compresses it to a column of letters
                // when the row runs out of width — which it does at three
                // rows of two pickers apiece.
                Text("to").font(.system(size: 12)).foregroundColor(.secondary).fixedSize()
                hourPicker(selection: endHour(slot), range: 1..<25)
            }
            // Disabled on the pickers rather than the row, so the checkbox
            // that turns the slot back on doesn't go with them.
            .disabled(!isWorked)

            Spacer(minLength: 0)
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: Self.labelWidth, alignment: .leading)
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

    /// Whether the day holds this slot at all. Switching one on gives it the
    /// hours it normally occupies and puts it back in reading order, which
    /// is the order the shifts are filled and the ghosts offered in.
    ///
    /// The last remaining slot can't be switched off: a schedule with no
    /// shifts has no hours to recommend and nothing to draw.
    private func worked(_ slot: ShiftTemplate.Slot) -> Binding<Bool> {
        Binding(
            get: { preferences.shifts.contains { $0.slot == slot } },
            set: { isOn in
                if isOn {
                    guard !preferences.shifts.contains(where: { $0.slot == slot }) else { return }
                    guard let placed = ShiftTemplate.placement(for: slot, avoiding: preferences.shifts) else { return }
                    preferences.shifts.append(placed)
                    preferences.shifts.sort { $0.slot.order < $1.slot.order }
                } else {
                    guard preferences.shifts.count > 1 else { return }
                    preferences.shifts.removeAll { $0.slot == slot }
                }
            }
        )
    }

    /// Start and end are edited through bindings that keep each shift at
    /// least an hour long, rather than letting the two pickers cross over
    /// into an end-before-start slot that nothing downstream can draw.
    ///
    /// A slot the day doesn't hold reads back the hours it would normally
    /// occupy — its pickers are disabled, but they still have to show
    /// something, and a value they have no option for renders blank.
    private func startHour(_ slot: ShiftTemplate.Slot) -> Binding<Double> {
        Binding(
            get: { shift(slot)?.startHour ?? ShiftTemplate.standard(for: slot).startHour },
            set: { newValue in
                guard let index = index(of: slot) else { return }
                preferences.shifts[index].startHour = newValue
                if preferences.shifts[index].endHour <= newValue {
                    preferences.shifts[index].endHour = min(newValue + 1, 24)
                }
            }
        )
    }

    private func endHour(_ slot: ShiftTemplate.Slot) -> Binding<Double> {
        Binding(
            get: { shift(slot)?.endHour ?? ShiftTemplate.standard(for: slot).endHour },
            set: { newValue in
                guard let index = index(of: slot) else { return }
                preferences.shifts[index].endHour = newValue
                if preferences.shifts[index].startHour >= newValue {
                    preferences.shifts[index].startHour = max(newValue - 1, 0)
                }
            }
        )
    }

    private func index(of slot: ShiftTemplate.Slot) -> Int? {
        preferences.shifts.firstIndex { $0.slot == slot }
    }

    private func shift(_ slot: ShiftTemplate.Slot) -> ShiftTemplate? {
        preferences.shifts.first { $0.slot == slot }
    }
}
