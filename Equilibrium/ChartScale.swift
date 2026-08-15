import CoreGraphics
import Foundation

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Shared 6am-midnight scale used by the bars, gridlines, and Y-axis labels.
/// (The *workday* span — 9-5 by default — is configurable via
/// `WorkPreferences` and threaded through separately; this is just the
/// fixed axis range everything gets plotted against.)
enum ChartScale {
    static let startHour: Double = 6
    static let endHour: Double = 24

    static func fraction(of hour: Double) -> Double {
        let range = endHour - startHour
        return (hour - startHour).clamped(to: 0...range) / range
    }

    /// The fraction-of-day for a `Date`'s time-of-day component, on this
    /// same scale — used to position anything with a real clock time
    /// (a meeting's start/end) rather than a plain hour number.
    static func fraction(of date: Date, calendar: Calendar = .current) -> Double {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60.0
        return fraction(of: hour)
    }

    /// Seconds of real time represented by one point of `chartHeight`, on
    /// this scale — used to convert a drag's point-delta into a time delta.
    static func secondsPerPoint(chartHeight: CGFloat) -> Double {
        guard chartHeight > 0 else { return 0 }
        return (endHour - startHour) * 3600 / Double(chartHeight)
    }
}
