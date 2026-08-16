import Foundation

/// Formats a non-negative duration in hours for display: rounded to the
/// nearest half hour, then shown as a whole number when there's no
/// fractional part ("8h"), or with the ½ symbol otherwise ("7½h", "½h")
/// — never "7.5h" and never a redundant ".0".
enum HoursFormat {
    static func string(_ hours: Double) -> String {
        let rounded = (hours * 2).rounded() / 2
        guard rounded.truncatingRemainder(dividingBy: 1) != 0 else {
            return "\(Int(rounded))h"
        }
        let whole = Int(rounded.rounded(.down))
        return whole == 0 ? "½h" : "\(whole)½h"
    }
}
