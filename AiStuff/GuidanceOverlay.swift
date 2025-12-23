import SwiftUI

struct GuidanceOverlay: View {
    let nosePoint: CGPoint?      // normalized 0..1
    let targetPoint: CGPoint     // normalized 0..1
    let isAligned: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            let target = CGPoint(x: targetPoint.x * w, y: targetPoint.y * h)

            // target ring
            Circle()
                .stroke(isAligned ? Color.green : Color.white, lineWidth: 2)
                .frame(width: 46, height: 46)
                .position(target)

            if let nose = nosePoint {
                let n = CGPoint(x: nose.x * w, y: nose.y * h)

                // dotted line
                Path { p in
                    p.move(to: n)
                    p.addLine(to: target)
                }
                .stroke(isAligned ? Color.green : Color.white,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6]))

                // nose dot
                Circle()
                    .fill(isAligned ? Color.green : Color.white)
                    .frame(width: 10, height: 10)
                    .position(n)
            }
        }
        .allowsHitTesting(false)
    }
}
