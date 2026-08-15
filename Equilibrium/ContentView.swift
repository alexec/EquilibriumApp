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

            DailyBarChartView(
                days: days,
                spans: days.map { viewModel.span(for: $0) },
                averageHours: { viewModel.averageHours(for: Array($0)) },
                recommendedHours: { viewModel.recommendedHours(for: $0) },
                onSave: { day, start, end, breakMinutes in
                    viewModel.setManualHours(for: day, start: start, end: end, breakMinutes: breakMinutes)
                },
                onClear: { day in viewModel.clearManualHours(for: day) },
                onDelete: { day in viewModel.deleteHours(for: day) }
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            viewModel.refresh()
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
