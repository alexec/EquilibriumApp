import SwiftUI

/// Popover for setting, overriding, or deleting a day's worked hours.
struct EditHoursPopover: View {
    let day: Date
    let existingSpan: WorkdaySpan?
    let onSave: (Date, Date, Int) -> Void
    let onRemoveOverride: () -> Void
    let onDelete: () -> Void

    @State private var startTime: Date
    @State private var endTime: Date
    @State private var breakMinutes: Int

    init(
        day: Date,
        existingSpan: WorkdaySpan?,
        onSave: @escaping (Date, Date, Int) -> Void,
        onRemoveOverride: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.day = day
        self.existingSpan = existingSpan
        self.onSave = onSave
        self.onRemoveOverride = onRemoveOverride
        self.onDelete = onDelete

        let calendar = Calendar.current
        let defaultStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        let defaultEnd = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day) ?? day
        _startTime = State(initialValue: TimeRounding.roundedToNearestHalfHour(existingSpan?.start ?? defaultStart))
        _endTime = State(initialValue: TimeRounding.roundedToNearestHalfHour(existingSpan?.end ?? defaultEnd))
        _breakMinutes = State(initialValue: existingSpan?.breakMinutes ?? 0)
    }

    private var dayLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: day)
    }

    private var hasData: Bool {
        (existingSpan?.hours ?? 0) > 0
    }

    private var breakLabel: String {
        let hours = breakMinutes / 60
        let minutes = breakMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dayLabel)
                .font(.headline)

            DatePicker("Start", selection: $startTime, displayedComponents: .hourAndMinute)
                .onChange(of: startTime) { newValue in
                    let rounded = TimeRounding.roundedToNearestHalfHour(newValue)
                    if rounded != newValue { startTime = rounded }
                }
            DatePicker("End", selection: $endTime, displayedComponents: .hourAndMinute)
                .onChange(of: endTime) { newValue in
                    let rounded = TimeRounding.roundedToNearestHalfHour(newValue)
                    if rounded != newValue { endTime = rounded }
                }

            Stepper(
                "Breaks: \(breakLabel)",
                value: $breakMinutes,
                in: 0...(23 * 60),
                step: TimeRounding.intervalMinutes
            )

            HStack {
                if hasData {
                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                }
                if existingSpan?.isManual == true {
                    Button("Remove Override") {
                        onRemoveOverride()
                    }
                }
                Spacer()
                Button("Save") {
                    onSave(startTime, endTime, breakMinutes)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
