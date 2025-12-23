import SwiftUI

struct NoseGuidanceOverlay: View {
    let nose: CGPoint?
    let target: CGPoint
    let tolerancePx: CGFloat

    var isAligned: Bool {
        guard let nose else { return false }
        let dx = nose.x - target.x
        let dy = nose.y - target.y
        return sqrt(dx*dx + dy*dy) <= tolerancePx
    }

    var body: some View {
        ZStack {
            // Target reticle
            Circle()
                .stroke(isAligned ? Color.green : Color.white.opacity(0.85), lineWidth: 2)
                .frame(width: 34, height: 34)
                .overlay(
                    Circle()
                        .fill(isAligned ? Color.green : Color.white.opacity(0.85))
                        .frame(width: 6, height: 6)
                )
                .position(target)

            if let nose {
                // Dotted guidance line
                Path { p in
                    p.move(to: nose)
                    p.addLine(to: target)
                }
                .stroke(isAligned ? Color.green.opacity(0.0) : Color.white.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 6]))

                // Nose dot
                Circle()
                    .fill(isAligned ? Color.green : Color.yellow)
                    .frame(width: 10, height: 10)
                    .shadow(radius: 2)
                    .position(nose)
            }
        }
        .allowsHitTesting(false)
    }
}
