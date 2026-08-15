import Foundation

/// Recommends how many hours to work on remaining unworked weekdays this
/// week, aiming for `weeklyTargetHours` (from `WorkPreferences`):
/// distributing (target - alreadyWorked) across the days left, or flagging
/// when you're already over budget.
enum WorkloadRecommender {
    /// Recommended hours to work on `date`, or nil if `date` isn't a
    /// remaining, unworked weekday in the current week (i.e. today or a
    /// future weekday this week with no recorded hours yet).
    ///
    /// Distributes (weeklyTargetHours - alreadyWorked) across the remaining
    /// unworked weekdays: weeklyTargetHours/5 per day greedily if there's
    /// enough runway left in the week, tapering the last day down to
    /// whatever's left; if behind pace, an even higher "requisite average"
    /// across those days; if already over budget, a negative "over by Xh"
    /// figure.
    static func recommendedHours(
        for date: Date,
        week: [Date],
        today: Date,
        weeklyTargetHours: Double,
        hoursWorked: (Date) -> Double,
        calendar: Calendar = .current
    ) -> Double? {
        guard !WeekCalendar.isWeekend(date, calendar: calendar) else { return nil }
        guard date >= today else { return nil }
        guard week.contains(date) else { return nil }
        guard hoursWorked(date) == 0 else { return nil }

        let recommendedDailyHours = weeklyTargetHours / 5

        let workedSoFar = week.reduce(0.0) { $0 + hoursWorked($1) }
        let remainingBudget = weeklyTargetHours - workedSoFar

        let remainingUnworkedWeekdays = week.filter { day in
            !WeekCalendar.isWeekend(day, calendar: calendar) && day >= today && hoursWorked(day) == 0
        }.sorted()

        guard let dayIndex = remainingUnworkedWeekdays.firstIndex(of: date) else { return nil }
        let daysLeft = remainingUnworkedWeekdays.count
        guard daysLeft > 0 else { return nil }

        if remainingBudget <= 0 {
            // Already at or over budget: split the overage evenly across
            // remaining days as a negative figure ("you're over by Xh").
            return remainingBudget / Double(daysLeft)
        }

        let atCapacity = recommendedDailyHours * Double(daysLeft)
        if remainingBudget <= atCapacity {
            // Greedy recommendedDailyHours/day, tapering the final day to
            // whatever remains.
            let fullDays = Int(remainingBudget / recommendedDailyHours)
            let leftover = remainingBudget - (Double(fullDays) * recommendedDailyHours)
            if dayIndex < fullDays {
                return recommendedDailyHours
            } else if dayIndex == fullDays {
                return leftover
            } else {
                return 0
            }
        } else {
            // Behind pace: even split across remaining days, uncapped.
            return remainingBudget / Double(daysLeft)
        }
    }
}
