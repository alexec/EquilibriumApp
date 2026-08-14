import SwiftUI

struct YAxisView: View {
    let hours: [Double]
    let chartHeight: CGFloat
    let width: CGFloat
    let label: (Double) -> String

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(hours, id: \.self) { hour in
                Text(label(hour))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.8))
                    .frame(width: width, alignment: .trailing)
                    .offset(y: CGFloat(ChartScale.fraction(of: hour)) * chartHeight - 6)
            }
        }
        .frame(width: width, height: chartHeight, alignment: .topLeading)
    }
}
