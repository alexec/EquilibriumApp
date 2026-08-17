import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: WorkHistoryViewModel
    @State private var showsPreferences = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // Clear the traffic-light cluster on the hidden title bar.
                Color.clear.frame(width: 56, height: 12)
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
                    PreferencesView(
                        current: viewModel.preferences,
                        calendars: viewModel.availableCalendars,
                        calendarSelection: viewModel.calendarSelection,
                        onCalendarSelectionChange: { viewModel.updateCalendarSelection($0) }
                    ) { updated in
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
                onWorkdayChange: { day, newStart, newEnd in
                    viewModel.updateWorkday(for: day, newStart: newStart, newEnd: newEnd)
                },
                onResetMeetings: { day in viewModel.resetMeetings(for: day) },
                onDelete: { day in viewModel.deleteHours(for: day) }
            )

            Button(dailyPromptTitle) {
                viewModel.presentDailyPrompt(dailyPromptKind)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: dailyPromptBinding) { kind in
            switch kind {
            case .intention:
                IntentionView(
                    meetings: viewModel.todayMeetings(),
                    existing: viewModel.todayIntention(),
                    onSave: { goals, outcomes in
                        viewModel.saveIntention(goals: goals, outcomes: outcomes)
                    },
                    onCancel: { viewModel.dismissDailyPrompt() }
                )
            case .checkIn:
                CheckInView(
                    meetings: viewModel.todayMeetings(),
                    intention: viewModel.todayIntention(),
                    onSave: { reflection in
                        viewModel.saveCheckIn(reflection: reflection)
                    },
                    onCancel: { viewModel.dismissDailyPrompt() }
                )
            }
        }
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

    /// One control: morning intention until it's set, then end-of-day check-in.
    private var dailyPromptKind: DailyPromptKind {
        viewModel.todayIntention()?.hasIntention == true ? .checkIn : .intention
    }

    private var dailyPromptTitle: String {
        switch dailyPromptKind {
        case .intention: return "Set intention"
        case .checkIn: return "Check in"
        }
    }

    /// Bridges `presentedDailyPrompt` to `.sheet(item:)` without Optional wrangling in the call site.
    private var dailyPromptBinding: Binding<DailyPromptKind?> {
        Binding(
            get: { viewModel.presentedDailyPrompt },
            set: { viewModel.presentedDailyPrompt = $0 }
        )
    }
}

extension DailyPromptKind: Identifiable {
    var id: String {
        switch self {
        case .intention: return "intention"
        case .checkIn: return "checkIn"
        }
    }
}
