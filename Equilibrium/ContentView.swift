import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: WorkHistoryViewModel
    @State private var showsPreferences = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button {
                    showsPreferences = true
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsPreferences) {
                    PreferencesView(current: viewModel.preferences) { updated in
                        viewModel.updatePreferences(updated)
                        showsPreferences = false
                    }
                }
            }

            DailyBarChartView(
                days: days,
                spans: days.map { viewModel.span(for: $0) },
                recommendedHours: { viewModel.recommendedHours(for: $0) },
                workdayStartHour: viewModel.preferences.workdayStartHour,
                workdayEndHour: viewModel.preferences.workdayEndHour,
                weeklyTargetHours: viewModel.preferences.weeklyTargetHours,
                aiWeekSummary: { weekStart in viewModel.weekHeaderSummary(forWeekStarting: weekStart) },
                onMeetingChange: { day, meetingID, newStart, newEnd in
                    viewModel.updateMeeting(for: day, meetingID: meetingID, newStart: newStart, newEnd: newEnd)
                },
                onResetMeetings: { day in viewModel.resetMeetings(for: day) },
                onDelete: { day in viewModel.deleteHours(for: day) }
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            Task {
                await viewModel.requestCalendarAccessAndRefresh()
            }
            viewModel.startAutoRefresh()
        }
        .onDisappear {
            viewModel.stopAutoRefresh()
        }
    }

    private var days: [Date] {
        viewModel.rollingWindowDays(weeks: 2)
    }
}
