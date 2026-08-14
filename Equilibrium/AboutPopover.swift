import SwiftUI

/// The "why I built this" story shown from the header's info button.
struct AboutPopover: View {
    private let story = """
    I felt like I was working too many hours at the same time I knew those \
    extra hours weren't producing fantastic extra output. I didn't feel \
    focused in my work. I wanted a way to make sure I didn't work too hard, \
    and that would also push me at the same time to be focused in my work.

    Encouraging you to work the right number of hours both helps you to \
    focus and to relax, and to get the right work-life balance.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why Equilibrium")
                .font(.headline)
            Text(story)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 280)
    }
}
