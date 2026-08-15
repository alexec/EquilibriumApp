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
}
