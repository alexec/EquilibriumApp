import Foundation

/// Clips times to the nearest 30-minute mark, used when manually setting or
/// displaying worked hours so entries stay on a consistent grid.
enum TimeRounding {
    static let intervalMinutes = 30

    static func roundedToNearestHalfHour(_ date: Date, calendar: Calendar = .current) -> Date {
        let interval = TimeInterval(intervalMinutes * 60)
        let referenceTime = date.timeIntervalSinceReferenceDate
        let rounded = (referenceTime / interval).rounded() * interval
        return Date(timeIntervalSinceReferenceDate: rounded)
    }
}
