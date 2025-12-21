import SwiftUI

struct ArcZoomDial: View {
    let currentZoom: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat
    let presets: [CGFloat]
    
    // Configuration
    private let arcAngle: Double = 140 // Total span in degrees
    private let radius: CGFloat = 300 // Radius of the dial
    
    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height + radius - 60)
            
            ZStack {
                // 1. TICKS
                let ticks = generateTicks()
                ForEach(ticks.indices, id: \.self) { index in
                    let tick = ticks[index]
                    TickMark(
                        tick: tick,
                        center: center,
                        radius: radius,
                        arcAngle: arcAngle,
                        currentZoom: currentZoom
                    )
                }
                
                // 2. INDICATOR (Static)
                IndicatorTriangle()
                    .fill(Color.yellow)
                    .frame(width: 14, height: 9)
                    .position(x: geo.size.width / 2, y: 10)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            }
            .drawingGroup() // High performance rendering
            .mask(
                DialMask(center: center, radius: radius, width: 200)
            )
        }
        .frame(height: 100)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.8), Color.black.opacity(0.0)],
                startPoint: .bottom,
                endPoint: .top
            )
            .mask(ArcShape(radius: radius, width: 150))
            .offset(y: 30)
        )
    }
    
    // MARK: - MATH (Purely for drawing now)
    
    private func generateTicks() -> [TickInfo] {
        var ticks: [TickInfo] = []
        // Majors
        for preset in presets { ticks.append(TickInfo(zoom: preset, isMajor: true)) }
        
        // Minors
        var v = minZoom
        while v < maxZoom {
            let nextV = v * 2
            let step = (log2(nextV) - log2(v)) / 5
            for i in 1...4 {
                let zoomVal = pow(2, log2(v) + step * Double(i))
                if zoomVal < maxZoom { ticks.append(TickInfo(zoom: zoomVal, isMajor: false)) }
            }
            v = nextV
        }
        return ticks.sorted { $0.zoom < $1.zoom }
    }
}

// (TickInfo, TickMark, Shapes remain exactly the same as before, just ensuring they compile)
struct TickInfo { let zoom: CGFloat; let isMajor: Bool }

struct TickMark: View {
    let tick: TickInfo
    let center: CGPoint
    let radius: CGFloat
    let arcAngle: Double
    let currentZoom: CGFloat
    
    var body: some View {
        let angle = zoomToAngle(tick.zoom)
        let currentAngle = zoomToAngle(currentZoom)
        let delta = angle - currentAngle
        let isVisible = abs(delta) < (arcAngle/2 + 5)
        
        if isVisible {
            ZStack {
                Rectangle()
                    .fill(tick.isMajor ? Color.white : Color.white.opacity(0.4))
                    .frame(width: tick.isMajor ? 2 : 1, height: tick.isMajor ? 16 : 8)
                    .offset(y: -radius)
                
                if tick.isMajor {
                    VStack(spacing: 2) {
                        Text(formatLabel(tick.zoom))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(abs(delta) < 4 ? .yellow : .white)
                            .shadow(color: .black.opacity(0.3), radius: 1)
                        Text(focalLength(for: tick.zoom))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.yellow)
                            .opacity(abs(delta) < 4 ? 1 : 0)
                    }
                    .rotationEffect(.degrees(-delta))
                    .offset(y: -radius - 25)
                }
            }
            .rotationEffect(.degrees(delta))
            .position(x: center.x, y: center.y)
        }
    }
    
    private func zoomToAngle(_ zoom: CGFloat) -> Double {
        let minLog = log2(0.5)
        let maxLog = log2(15.0)
        let logZoom = log2(zoom)
        let percent = (logZoom - minLog) / (maxLog - minLog)
        return -70 + (percent * 140)
    }
    private func formatLabel(_ val: CGFloat) -> String { return val == 0.5 ? ".5" : String(format: "%.0f", val) }
    private func focalLength(for val: CGFloat) -> String {
        switch val {
        case 0.5: return "13mm"; case 1.0: return "24mm"; case 2.0: return "48mm"; case 4.0: return "120mm"; default: return ""
        }
    }
}

// Shapes
struct IndicatorTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
struct DialMask: Shape {
    let center: CGPoint; let radius: CGFloat; let width: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: center, radius: radius + 60, startAngle: .degrees(-160), endAngle: .degrees(-20), clockwise: false)
        path.addLine(to: center)
        path.closeSubpath()
        return path
    }
}
struct ArcShape: Shape {
    let radius: CGFloat; let width: CGFloat
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.maxY + radius - 60)
        var path = Path()
        path.addArc(center: center, radius: radius + width/2, startAngle: .degrees(-160), endAngle: .degrees(-20), clockwise: false)
        path.addArc(center: center, radius: radius - width/2, startAngle: .degrees(-20), endAngle: .degrees(-160), clockwise: true)
        path.closeSubpath()
        return path
    }
}
