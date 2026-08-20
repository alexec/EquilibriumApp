import SwiftUI

/// Lays subviews out left to right, wrapping onto a new line when the next
/// one won't fit — the way words fill a paragraph.
///
/// SwiftUI has no wrapping stack. The alternative was a horizontally
/// scrolling row, which is what the people strip used to be, and it hid
/// everyone past the third or fourth person behind a scroll gesture nobody
/// makes. Filling downward puts them all on screen at once.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(subviews: subviews, in: width)
        let height = lines.reduce(CGFloat.zero) { total, line in
            total + line.height + (total == 0 ? 0 : lineSpacing)
        }
        return CGSize(width: width == .infinity ? widest(lines) : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = arrange(subviews: subviews, in: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Line {
        var items: [Item] = []
        var height: CGFloat = 0
    }

    /// Groups the subviews into lines that fit `width`. A subview wider than
    /// the whole line still gets its own line rather than being dropped.
    private func arrange(subviews: Subviews, in width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : x + spacing + size.width
            if !current.items.isEmpty, needed > width {
                lines.append(current)
                current = Line()
                x = 0
            }
            x = current.items.isEmpty ? size.width : x + spacing + size.width
            current.items.append(Item(index: index, size: size))
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { lines.append(current) }
        return lines
    }

    private func widest(_ lines: [Line]) -> CGFloat {
        lines.reduce(CGFloat.zero) { widest, line in
            let lineWidth = line.items.reduce(CGFloat.zero) { $0 + $1.size.width + spacing }
            return max(widest, max(0, lineWidth - spacing))
        }
    }
}
