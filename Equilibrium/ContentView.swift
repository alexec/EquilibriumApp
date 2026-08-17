import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: WorkHistoryViewModel
    @State private var showsPreferences = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            chartColumn

            let editor = viewModel.dayEditor
            DayDetailPanel(
                day: editor.day,
                meetings: viewModel.meetings(for: editor.day),
                existing: viewModel.intention(for: editor.day),
                allowsCheckIn: editor.day <= Calendar.current.startOfDay(for: Date()),
                calendarAccessGranted: viewModel.calendarAccessGranted,
                initialFocus: editor.kind,
                // Nothing to dismiss and nothing to confirm: text is written
                // as it's typed, and the day's button filling in behind the
                // panel is the confirmation.
                onSave: { goals, outcomes, reflection in
                    viewModel.saveDayEntry(
                        day: editor.day,
                        goals: goals,
                        outcomes: outcomes,
                        reflection: reflection
                    )
                }
            )
            // Rebuilt when the day changes so its fields reload from that
            // day's saved text rather than keeping the last day's edits in
            // @State — and so the outgoing day's pending write is flushed by
            // its `onDisappear`.
            .id(editor.day)
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

    private var chartColumn: some View {
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

            // Read once and passed to both parameters: the week is derived
            // from "now" on each read, so two reads either side of midnight
            // would label bars with one week's dates and fill them with
            // another week's hours.
            let days = viewModel.visibleWeekDays

            DailyBarChartView(
                days: days,
                spans: days.map { viewModel.span(for: $0) },
                recommendedHours: { viewModel.recommendedHours(for: $0) },
                workdayStartHour: viewModel.preferences.workdayStartHour,
                workdayEndHour: viewModel.preferences.workdayEndHour,
                weeklyTargetHours: viewModel.preferences.weeklyTargetHours,
                aiWeekSummary: { weekStart in viewModel.weekHeaderSummary(forWeekStarting: weekStart) },
                weekLabel: viewModel.visibleWeekLabel,
                canShowPreviousWeek: viewModel.canShowPreviousWeek,
                canShowNextWeek: viewModel.canShowNextWeek,
                onShowPreviousWeek: { viewModel.showPreviousWeek() },
                onShowNextWeek: { viewModel.showNextWeek() },
                intention: { day in viewModel.intention(for: day) },
                selection: viewModel.dayEditor,
                onSelectDay: { day, kind in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.selectDay(day, kind: kind)
                    }
                },
                onMeetingChange: { day, meetingID, newStart, newEnd in
                    viewModel.updateMeeting(for: day, meetingID: meetingID, newStart: newStart, newEnd: newEnd)
                },
                onWorkdayChange: { day, newStart, newEnd in
                    viewModel.updateWorkday(for: day, newStart: newStart, newEnd: newEnd)
                },
                onResetMeetings: { day in viewModel.resetMeetings(for: day) },
                onDelete: { day in viewModel.deleteHours(for: day) }
            )
        }
    }
}
