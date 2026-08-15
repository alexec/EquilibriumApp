import Foundation

/// Formats a non-negative duration in hours for display: rounded to the
/// nearest half hour, then shown as a whole number when there's no
/// fractional part ("8h") or a half otherwise ("7.5h") — never a
/// redundant ".0", and never any other decimal.
enum HoursFormat {
    static func string(_ hours: Double) -> String {
        let rounded = (hours * 2).rounded() / 2
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))h"
        }
        return "\(rounded)h"
    }
}
