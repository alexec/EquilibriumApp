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
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(insight)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DailyBarChartView(
                days: days,
                spans: days.map { viewModel.span(for: $0) },
                averageHours: { viewModel.averageHours(for: Array($0)) },
                meetingPercentage: { viewModel.meetingPercentage(for: Array($0)) },
                recommendedHours: { viewModel.recommendedHours(for: $0) },
                rollingAverageHoursPerDay: viewModel.rollingAverageHoursPerDay(),
                onSave: { day, start, end, breakMinutes in
                    viewModel.setManualHours(for: day, start: start, end: end, breakMinutes: breakMinutes)
                },
                onClear: { day in viewModel.clearManualHours(for: day) },
                onDelete: { day in viewModel.deleteHours(for: day) }
            )

            if let insight = viewModel.rollingAverageInsight {
                Text(insight)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
