import SwiftUI

/// The width of the two columns either side of the chart.
///
/// One constant, because they are the same width and looked wrong when
/// they weren't: the inbox and the day panel are the two text columns
/// framing the week, and an inbox wider than the panel opposite reads as a
/// mistake rather than as emphasis. Fixed rather than flexible so they stay
/// equal at every window size — sharing slack between two flexible columns
/// and a flexible chart divides it by rules nobody can see.
enum SideColumn {
    static let width: CGFloat = 300
}

struct ContentView: View {
    @ObservedObject var viewModel: WorkHistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            columns
            Divider()
            PeopleStrip(people: viewModel.currentPeople)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            Task {
                await viewModel.requestCalendarAccessAndRefresh()
            }
            Task {
                await viewModel.refreshMail()
            }
        }
        .sheet(isPresented: $viewModel.showsWeekRanking) {
            // Read once as the sheet opens rather than on every body pass:
            // the list is a snapshot of finished weeks, and nothing behind
            // the sheet can change them while it's up.
            let summaries = viewModel.rankedWeeks()
            WeekRankingView(
                summaries: summaries,
                comparison: WeekRanking.comparison(summaries),
                onClose: { viewModel.showsWeekRanking = false }
            )
        }
        // A sheet rather than the popover this used to be: the gear it hung
        // from is gone, and settings opened from a menu has nothing in the
        // window to point at.
        .sheet(isPresented: $viewModel.showsPreferences) {
            PreferencesView(
                current: viewModel.preferences,
                calendars: viewModel.availableCalendars,
                calendarSelection: viewModel.calendarSelection,
                onCalendarSelectionChange: { viewModel.updateCalendarSelection($0) },
                mailAccounts: viewModel.mailAccounts,
                mailSelection: viewModel.mailSelection,
                mailScope: viewModel.mailScope,
                onMailSelectionChange: { viewModel.updateMailSelection($0) }
            ) { updated in
                viewModel.updatePreferences(updated)
                viewModel.showsPreferences = false
            }
            .padding(20)
            // A popover closed itself when you clicked away; a sheet has to
            // be given a way out, and Escape has to work.
            .overlay(alignment: .topTrailing) {
                Button {
                    viewModel.showsPreferences = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(10)
            }
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 16) {
            MailColumn(
                messages: viewModel.visibleMailMessages,
                summary: { viewModel.summary(for: $0) },
                access: viewModel.mailAccess,
                brief: viewModel.dayBrief,
                briefFallback: viewModel.dayBriefFallback,
                onRefresh: { Task { await viewModel.refreshMail() } },
                onOpen: { MailLinks.open(messageID: $0.id) },
                recommendedBlock: { viewModel.recommendedBlock(for: $0, minutes: $1) },
                blockableDays: viewModel.blockableDays(),
                blockStartTimes: { viewModel.blockStartTimes(on: $0, minutes: $1) },
                onBlockTime: { viewModel.addFocusBlock(for: $0, slot: $1) },
                onArchive: { message in Task { await viewModel.archive(message) } },
                archiveProblem: viewModel.archiveProblem ?? viewModel.deferProblem,
                deferralDate: { viewModel.deferralDate(for: $0) },
                onDefer: { message, date in
                    Task { await viewModel.deferMessage(message, until: date) }
                },
                onUndefer: { message in
                    Task { await viewModel.undeferMessage(message) }
                },
                deferredCount: viewModel.deferredCount,
                showsDeferred: $viewModel.showsDeferred
            )

            chartColumn

            let editor = viewModel.dayEditor
            DayDetailPanel(
                day: editor.day,
                meetings: viewModel.meetings(for: editor.day),
                existing: viewModel.intention(for: editor.day),
                allowsCheckIn: editor.day <= Calendar.current.startOfDay(for: Date()),
                calendarAccess: viewModel.calendarAccess,
                meetingGist: viewModel.meetingGist(for: editor.day),
                initialFocus: editor.kind,
                deleteProblem: viewModel.meetingDeleteProblem,
                onDeleteMeeting: { meeting, scope in
                    Task { await viewModel.deleteMeeting(meeting, scope: scope) }
                },
                // Nothing to dismiss and nothing to confirm: words are
                // written as they're recognised, and the day's button
                // filling in behind the panel is the confirmation.
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
    }

    private var chartColumn: some View {
        // No header row above the chart any more. It held the gear, which
        // has moved to the app menu, and then held nothing but a spinner —
        // and an empty row above one card and not the others is exactly the
        // misalignment it was meant to prevent. The spinner now sits on the
        // card it describes.
        //
        // A stack rather than the `Group` this was: a Group's children are
        // laid out by whatever contains it, so once the weekly question
        // joined the chart in here, the two became columns of the HStack
        // outside rather than one column with a card under it.
        VStack(alignment: .leading, spacing: 16) {
            // Read once and used for everything the chart shows — bars,
            // hours and the week's name. The week is derived from "now" on
            // each read, so separate reads either side of midnight would
            // dress one week's bars in another week's hours and title.
            let days = viewModel.visibleWeekDays

            DailyBarChartView(
                days: days,
                spans: days.map { viewModel.span(for: $0) },
                recommendedHours: { viewModel.recommendedHours(for: $0) },
                meetings: { viewModel.chartMeetings(for: $0) },
                shiftTemplates: viewModel.preferences.shifts,
                weeklyTargetHours: viewModel.preferences.weeklyTargetHours,
                aiWeekSummary: { weekStart in viewModel.weekHeaderSummary(forWeekStarting: weekStart) },
                weekLabel: viewModel.weekLabel(for: days),
                canShowPreviousWeek: viewModel.canShowPreviousWeek,
                canShowNextWeek: viewModel.canShowNextWeek,
                onShowPreviousWeek: { viewModel.showPreviousWeek() },
                onShowNextWeek: { viewModel.showNextWeek() },
                selection: viewModel.dayEditor,
                onSelectDay: { day in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.selectDay(day)
                    }
                },
                onShiftChange: { day, shiftID, newStart, newEnd in
                    viewModel.updateShift(for: day, shiftID: shiftID, start: newStart, end: newEnd)
                },
                onShiftAdd: { day, newStart, newEnd in
                    viewModel.addShift(for: day, start: newStart, end: newEnd)
                },
                onShiftRemove: { day, shiftID in
                    viewModel.removeShift(for: day, shiftID: shiftID)
                },
                onDelete: { day in viewModel.deleteHours(for: day) },
                onShowAllWeeks: { viewModel.showsWeekRanking = true }
            )
            .overlay(alignment: .topTrailing) {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(12)
                }
            }

            // Under the chart, and only once the week it's about has
            // finished. Rebuilt per week so paging back to an answered week
            // shows that week's words rather than keeping the last one's in
            // @State — and so the outgoing week's pending write is flushed
            // by the card's `onDisappear`, the same trick the day panel uses.
            if let weekStart = days.first, viewModel.weekIsReviewable(weekStarting: weekStart) {
                WeeklyReviewCard(
                    existing: viewModel.weeklyReview(forWeekStarting: weekStart),
                    hours: viewModel.weeklyHours(forWeekStarting: weekStart),
                    onSave: { answer, verdict in
                        viewModel.saveWeeklyReview(
                            weekStarting: weekStart,
                            answer: answer,
                            verdict: verdict
                        )
                    }
                )
                .id(weekStart)
            }
        }
    }
}
