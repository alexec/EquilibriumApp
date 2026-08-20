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

    /// The same, but measured against the day the bar belongs to rather
    /// than read off the clock. The midnight that *ends* a day is stored as
    /// the start of the next one, which `fraction(of:)` above sees as 00:00
    /// and puts at the top of the chart — so a shift running to midnight
    /// was drawn as a stub at its own start instead of reaching the bottom.
    static func fraction(of date: Date, onDayStarting midnight: Date) -> Double {
        fraction(of: date.timeIntervalSince(midnight) / 3600.0)
    }

    /// Seconds of real time represented by one point of `chartHeight`, on
    /// this scale — used to convert a drag's point-delta into a time delta.
    static func secondsPerPoint(chartHeight: CGFloat) -> Double {
        guard chartHeight > 0 else { return 0 }
        return (endHour - startHour) * 3600 / Double(chartHeight)
    }

    /// The inverse of `fraction(of:)`: the hour-of-day a given fraction
    /// (0...1) down the chart corresponds to. Used to turn a raw drag
    /// position into a clock time when drawing a brand-new workday span.
    static func hour(atFraction fraction: Double) -> Double {
        startHour + fraction.clamped(to: 0...1) * (endHour - startHour)
    }
}
