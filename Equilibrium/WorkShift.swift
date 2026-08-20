import Foundation

/// One stretch of work within a day. A day holds up to three of them —
/// morning, afternoon, evening — and the gaps between them are the breaks:
/// lunch and dinner are no longer worked time that gets subtracted again
/// afterwards, they're simply the space where no shift is.
struct WorkShift: Codable, Identifiable, Equatable {
    let id: UUID
    var start: Date
    var end: Date

    init(id: UUID = UUID(), start: Date, end: Date) {
        self.id = id
        self.start = start
        self.end = end
    }

    var hours: Double {
        max(0, end.timeIntervalSince(start)) / 3600.0
    }
}

/// The rules a day's shifts are held to, in one place because three
/// different things produce them — the wake/sleep calculator, a click on a
/// ghost, a drag — and all three have to arrive at the same shape.
enum ShiftPlan {
    /// Morning, afternoon, evening. A day that wants a fourth stretch is a
    /// day whose breaks weren't really breaks; see `normalize`.
    static let maximumShifts = 3

    /// Sorts a day's shifts, merges any that overlap or meet, and folds the
    /// day down to `maximumShifts` if it still holds more.
    ///
    /// Merging on contact is the whole of the "extend one onto the next and
    /// they become one" behaviour: nothing special happens at the moment of
    /// contact, the two simply stop being two.
    ///
    /// Folding closes the narrowest gap first, repeatedly, which keeps the
    /// day's real shape — the long breaks stay breaks and a ten-minute one
    /// stops pretending to be the boundary of a shift. The time inside a
    /// closed gap wasn't worked, so it comes back as `absorbedGapMinutes`
    /// for the caller to keep deducting.
    static func normalize(_ shifts: [WorkShift]) -> (shifts: [WorkShift], absorbedGapMinutes: Int) {
        let ordered = shifts.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !ordered.isEmpty else { return ([], 0) }

        var merged: [WorkShift] = []
        for shift in ordered {
            if let last = merged.last, shift.start <= last.end {
                // The earlier shift's identity survives, so a drag that
                // swallows its neighbour goes on being the block you have
                // hold of rather than jumping to another one mid-gesture.
                merged[merged.count - 1].end = max(last.end, shift.end)
            } else {
                merged.append(shift)
            }
        }

        var absorbed: TimeInterval = 0
        while merged.count > maximumShifts {
            var narrowestIndex = 0
            var narrowestGap = TimeInterval.greatestFiniteMagnitude
            for index in 0..<(merged.count - 1) {
                let gap = merged[index + 1].start.timeIntervalSince(merged[index].end)
                if gap < narrowestGap {
                    narrowestGap = gap
                    narrowestIndex = index
                }
            }
            absorbed += max(narrowestGap, 0)
            merged[narrowestIndex].end = merged[narrowestIndex + 1].end
            merged.remove(at: narrowestIndex + 1)
        }

        return (merged, Int((absorbed / 60).rounded()))
    }
}
