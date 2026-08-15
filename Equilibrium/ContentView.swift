import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: WorkHistoryViewModel
    @State private var showsAbout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button {
                    showsAbout = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsAbout) {
                    AboutPopover()
                }
            }

            if let insight = viewModel.weeklyInsight {
                Text(insight)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DailyBarChartView(
                days: days,
                spans: days.map { viewModel.span(for: $0) },
                recommendedHours: { viewModel.recommendedHours(for: $0) },
                aiWeekSummary: { weekStart in viewModel.weekHeaderSummary(forWeekStarting: weekStart) },
                onMeetingSplitChange: { day, minutes in
                    viewModel.setMeetingSplit(for: day, meetingMinutes: minutes)
                },
                onResetMeetingSplit: { day in viewModel.resetMeetingSplit(for: day) },
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
