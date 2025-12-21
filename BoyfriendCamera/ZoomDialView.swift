import SwiftUI
import CoreHaptics

struct ZoomDialView: View {
    @Binding var zoomFactor: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat
    
    // Config
    private let dialRange: CGFloat = 40 // How many "degrees" wide the view is
    private let spacing: CGFloat = 8.0  // Visual spacing between ticks
    private let segmentAngle: Double = 2.0 // Degrees per tick
    
    @State private var dragOffset: CGFloat = 0
    @State private var lastHapticValue: Int = 0
    @State private var isDragging: Bool = false
    
    // Haptics
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            
            // The visual center of the arc
            let pivotY = height * 2.0 // Push the pivot point far down to create a gentle arc
            
            ZStack {
                // Background Mask to fade edges
                LinearGradient(
                    gradient: Gradient(colors: [.clear, .black, .black, .clear]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width, height: 50)
                .position(x: width / 2, y: height - 40)
                .opacity(0.8) // Only affects the ticks inside
                .mask(
                    // The Actual Ticks
                    ZStack {
                        ForEach(tickMarks(width: width), id: \.val) { tick in
                            VStack {
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: tick.isMajor ? 2 : 1, height: tick.isMajor ? 16 : 10)
                                    .shadow(color: .black, radius: 1)
                                
                                if tick.isMajor {
                                    Text("\(Int(tick.val))")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundColor(.white)
                                        .shadow(color: .black, radius: 1)
                                        .padding(.top, 4)
                                }
                            }
                            // Calculate rotation for the arc effect
                            .rotationEffect(.degrees(tick.angle), anchor: .bottom)
                            // Position relative to the pivot point far below
                            .position(x: width / 2, y: height - 20)
                            .offset(y: -pivotY) // Pull back up
                            .rotationEffect(.degrees(-tick.angle), anchor: .center) // Counter-rotate text
                            .rotationEffect(.degrees(tick.angle), anchor: .init(x: 0.5, y: (height - 20 + pivotY) / height))
                        }
                    }
                )

                // The Center Indicator (Yellow Triangle/Line)
                VStack(spacing: 4) {
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 8))
                        .rotationEffect(.degrees(180))
                        .foregroundColor(.yellow)
                    Rectangle()
                        .fill(Color.yellow)
                        .frame(width: 2, height: 20)
                }
                .position(x: width / 2, y: height - 30)
                .shadow(color: .black.opacity(0.5), radius: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isDragging { isDragging = true }
                        
                        // Calculate Zoom Sensitivity
                        // Slower zoom speed at higher zoom levels for precision
                        let sensitivity: CGFloat = zoomFactor > 5 ? 0.005 : 0.01
                        let delta = -value.translation.width * sensitivity
                        
                        // Apply Zoom
                        let newZoom = max(minZoom, min(maxZoom, zoomFactor + delta))
                        
                        // Smoothly update
                        withAnimation(.interactiveSpring()) {
                            zoomFactor = newZoom
                        }
                        
                        // Haptics for major steps
                        let intZoom = Int(newZoom)
                        if intZoom != lastHapticValue && intZoom == Int(newZoom.rounded()) {
                            hapticGenerator.impactOccurred()
                            lastHapticValue = intZoom
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
    }
    
    // Logic to generate only visible ticks
    struct Tick {
        let val: CGFloat
        let angle: Double
        let isMajor: Bool
    }
    
    private func tickMarks(width: CGFloat) -> [Tick] {
        var ticks: [Tick] = []
        
        // Determine density based on zoom level
        let step: CGFloat = zoomFactor > 5.0 ? 0.5 : 0.1
        let rangeLimit = 15.0 // How many zoom units to look ahead/behind
        
        let start = max(minZoom, floor(zoomFactor - rangeLimit))
        let end = min(maxZoom, ceil(zoomFactor + rangeLimit))
        
        // Loop through reasonable range
        var i = start
        while i <= end {
            // Calculate screen position angle relative to center
            let diff = i - zoomFactor
            // Spread factor: spacing between ticks on screen
            let angle = Double(diff) * (zoomFactor < 2 ? 15.0 : 8.0)
            
            // Only add if within visual bounds (approx +/- 40 degrees)
            if abs(angle) < 45 {
                let isMajor = abs(i.truncatingRemainder(dividingBy: 1.0)) < 0.001
                ticks.append(Tick(val: i, angle: angle, isMajor: isMajor))
            }
            i += step
        }
        return ticks
    }
}
