import SwiftUI

struct FloatingTargetView: View {
    let angleDiff: Double // How far off center the target is (-180 to 180)
    let isLocked: Bool
    
    // iPhone wide camera horizontal Field of View is roughly 60 degrees.
    // We use this to map angles to screen pixels.
    let fieldOfView: Double = 60.0
    
    var body: some View {
        GeometryReader { geo in
            // 1. Calculate the position
            // If target is 30° right, it should be at the right edge of the screen.
            // Screen Width / FOV = Pixels per degree.
            let pixelsPerDegree = geo.size.width / fieldOfView
            let xOffset = CGFloat(angleDiff * pixelsPerDegree)
            
            // 2. The Target Box UI
            ZStack {
                // Outer Brackets
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10, 5])) // Dashed line look
                    .frame(width: 100, height: 100)
                
                // Inner Corners (for that sci-fi look)
                VStack {
                    HStack {
                        EdgeBorder(edges: [.top, .leading])
                        Spacer()
                        EdgeBorder(edges: [.top, .trailing])
                    }
                    Spacer()
                    HStack {
                        EdgeBorder(edges: [.bottom, .leading])
                        Spacer()
                        EdgeBorder(edges: [.bottom, .trailing])
                    }
                }
                .frame(width: 80, height: 80)
                
                // Label
                if isLocked {
                    Text("LOCKED")
                        .font(.caption)
                        .bold()
                        .padding(4)
                        .background(Color.green)
                        .foregroundColor(.black)
                        .cornerRadius(4)
                        .offset(y: 60)
                }
            }
            // Color logic: Green if locked, Yellow if on screen, Red if off screen
            .foregroundColor(targetColor)
            .shadow(color: targetColor.opacity(0.5), radius: 10)
            // Center the box, then apply the calculated offset
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .offset(x: xOffset)
            // Animation makes it slide smoothly
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: xOffset)
            // Hide it if it's way off screen so it doesn't look weird
            .opacity(abs(angleDiff) > 40 ? 0 : 1)
        }
    }
    
    var targetColor: Color {
        if isLocked { return .green }
        if abs(angleDiff) < 30 { return .yellow }
        return .red.opacity(0.5)
    }
}

// Helper shape to draw just the corners
struct EdgeBorder: Shape {
    var edges: Edge.Set
    var length: CGFloat = 20
    var thickness: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if edges.contains(.top) {
            path.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness))
        }
        if edges.contains(.bottom) {
            path.addRect(CGRect(x: rect.minX, y: rect.maxY - thickness, width: rect.width, height: thickness))
        }
        if edges.contains(.leading) {
            path.addRect(CGRect(x: rect.minX, y: rect.minY, width: thickness, height: rect.height))
        }
        if edges.contains(.trailing) {
            path.addRect(CGRect(x: rect.maxX - thickness, y: rect.minY, width: thickness, height: rect.height))
        }
        return path
    }
}

// Preview just the box
#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        FloatingTargetView(angleDiff: 15, isLocked: false)
    }
}
