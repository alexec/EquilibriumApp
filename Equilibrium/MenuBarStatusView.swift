import SwiftUI

/// The view shown inside the `MenuBarExtra` popover.
/// Displays today's hours worked and the remaining weekly budget,
/// and provides a button to open the main application window.
struct MenuBarStatusView: View {
    @ObservedObject var viewModel: WorkHistoryViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                statView(label: "Today", value: todayHoursText)
                Divider().frame(height: 32)
                statView(label: "Remaining", value: remainingText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            Button("Open Equilibrium") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 200)
    }

    // MARK: - Helpers

    private var todayHoursText: String {
        let hours = viewModel.span(for: Date())?.effectiveHours ?? 0
        return String(format: "%.1fh", hours)
    }

    private var remainingText: String {
        let remaining = viewModel.remainingWeeklyHours()
        if remaining >= 0 {
            return String(format: "%.1fh", remaining)
        } else {
            return String(format: "+%.1fh", -remaining)
        }
    }

    private func statView(label: String, value: String) -> some View {
        VStack(alignment: .center, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
