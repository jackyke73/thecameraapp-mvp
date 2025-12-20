import SwiftUI
import CoreHaptics

public enum ZoomDialStyle {
    case fullCircle
    case semicircleBottom
}

public enum ResolutionSelection: String, CaseIterable {
    case r24MP = "24MP"
    case r48MP = "48MP"
}

public enum FormatSelection: String, CaseIterable {
    case heic = "HEIC"
    case raw = "RAW"
}

public struct ZoomDialView: View {
    @Binding private var zoom: CGFloat
    private let minZoom: CGFloat
    private let maxZoom: CGFloat
    private let majorTicks: [CGFloat]
    private let style: ZoomDialStyle
    @Binding private var resolution: ResolutionSelection
    @Binding private var format: FormatSelection

    @State private var dragAngle: Angle?
    @State private var engine: CHHapticEngine?

    private let ringWidth: CGFloat = 20
    private let knobRadius: CGFloat = 16

    // Angles: full circle 360°, start at top (270° in unit circle)
    private let startAngle = Angle(degrees: -90)
    private let endAngle = Angle(degrees: 270)

    public init(
        zoom: Binding<CGFloat>,
        minZoom: CGFloat,
        maxZoom: CGFloat,
        majorTicks: [CGFloat],
        style: ZoomDialStyle = .semicircleBottom,
        resolution: Binding<ResolutionSelection> = .constant(.r24MP),
        format: Binding<FormatSelection> = .constant(.heic)
    ) {
        self._zoom = zoom
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.majorTicks = majorTicks.filter { $0 >= minZoom && $0 <= maxZoom }.sorted()
        self.style = style
        self._resolution = resolution
        self._format = format
    }

    private func zoomToAngle(_ zoom: CGFloat) -> Angle {
        switch style {
        case .fullCircle:
            let fraction = (zoom - minZoom) / (maxZoom - minZoom)
            let angleDegrees = -90 + fraction * 360
            return Angle(degrees: angleDegrees)
        case .semicircleBottom:
            // Map minZoom to 180° (left), maxZoom to 0° (right) along bottom semicircle
            let fraction = (zoom - minZoom) / (maxZoom - minZoom)
            let angleDegrees = 180 - fraction * 180 // 180° -> 0°
            return Angle(degrees: angleDegrees)
        }
    }

    private func angleToZoom(_ angle: Angle) -> CGFloat {
        switch style {
        case .fullCircle:
            var deg = angle.degrees
            while deg < -90 { deg += 360 }
            while deg > 270 { deg -= 360 }
            let fraction = (deg + 90) / 360
            let z = minZoom + fraction * (maxZoom - minZoom)
            return min(max(z, minZoom), maxZoom)
        case .semicircleBottom:
            // Expect degrees in [0, 180] where 180=left=minZoom, 0=right=maxZoom
            var deg = angle.degrees
            // Normalize to [0, 180]
            while deg < 0 { deg += 360 }
            while deg > 360 { deg -= 360 }
            if deg > 180 { deg = 180 } // clamp bottom arc
            let fraction = (180 - deg) / 180
            let z = minZoom + fraction * (maxZoom - minZoom)
            return min(max(z, minZoom), maxZoom)
        }
    }

    private func knobPosition(in size: CGSize, angle: Angle) -> CGPoint {
        let radius = (min(size.width, size.height) - ringWidth) / 2
        let center = CGPoint(x: size.width/2, y: size.height/2)
        let a = angle.radians - .pi/2 // rotate to SwiftUI coordinate system where 0 is right
        let x = center.x + cos(a) * radius
        let y = center.y + sin(a) * radius
        return CGPoint(x: x, y: y)
    }

    private func angleFrom(center: CGPoint, location: CGPoint) -> Angle {
        // Calculate angle in degrees from center to location, 0° is top (-90° unit circle)
        let vector = CGVector(dx: location.x - center.x, dy: location.y - center.y)
        let rad = atan2(vector.dy, vector.dx)
        let deg = rad * 180 / .pi
        // shift so that 0° is top = -90°
        let shifted = deg + 90
        return Angle(degrees: shifted)
    }

    private func bottomArcAngle(from center: CGPoint, location: CGPoint) -> Angle {
        // Compute angle with 0° at right, 180° at left, limited to bottom arc
        let vector = CGVector(dx: location.x - center.x, dy: location.y - center.y)
        let rad = atan2(vector.dy, vector.dx)
        var deg = rad * 180 / .pi
        if deg < 0 { deg += 360 }
        // For bottom semicircle, we want [0, 180]
        if deg > 180 { deg = 180 }
        return Angle(degrees: Double(deg))
    }

    @State private var lastTickIndex: Int?

    private func tickIndex(for zoomValue: CGFloat) -> Int? {
        for (i, tick) in majorTicks.enumerated() {
            if zoomValue < tick {
                return i > 0 ? i - 1 : nil
            }
        }
        return majorTicks.isEmpty ? nil : majorTicks.count - 1
    }

    private func prepareHaptics() {
        guard engine == nil else { return }
        do {
            let hapticEngine = try CHHapticEngine()
            try hapticEngine.start()
            engine = hapticEngine
        } catch {
            engine = nil
        }
    }

    private func playHaptic() {
        prepareHaptics()
        guard let engine = engine else { return }
        var events = [CHHapticEvent]()
        let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5)
        let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
        let event = CHHapticEvent(eventType: .hapticTransient,
                                  parameters: [intensity, sharpness],
                                  relativeTime: 0)
        events.append(event)

        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            // ignore error
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            DialContents(size: proxy.size,
                         zoom: $zoom,
                         minZoom: minZoom,
                         maxZoom: maxZoom,
                         majorTicks: majorTicks,
                         ringWidth: ringWidth,
                         knobRadius: knobRadius,
                         startAngle: startAngle,
                         endAngle: endAngle,
                         style: style,
                         resolution: $resolution,
                         format: $format,
                         prepareHaptics: prepareHaptics,
                         playHaptic: playHaptic,
                         zoomToAngle: zoomToAngle,
                         angleToZoom: angleToZoom,
                         knobPosition: knobPosition,
                         angleFrom: angleFrom,
                         bottomArcAngle: bottomArcAngle,
                         tickIndex: tickIndex,
                         lastTickIndex: $lastTickIndex)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear { prepareHaptics() }
    }
}

// MARK: - Decomposed subview to reduce type-checking complexity
private struct DialContents: View {
    let size: CGSize
    @Binding var zoom: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat
    let majorTicks: [CGFloat]
    let ringWidth: CGFloat
    let knobRadius: CGFloat
    let startAngle: Angle
    let endAngle: Angle

    let style: ZoomDialStyle
    @Binding var resolution: ResolutionSelection
    @Binding var format: FormatSelection

    let prepareHaptics: () -> Void
    let playHaptic: () -> Void
    let zoomToAngle: (CGFloat) -> Angle
    let angleToZoom: (Angle) -> CGFloat
    let knobPosition: (CGSize, Angle) -> CGPoint
    let angleFrom: (CGPoint, CGPoint) -> Angle
    let bottomArcAngle: (CGPoint, CGPoint) -> Angle
    let tickIndex: (CGFloat) -> Int?
    @Binding var lastTickIndex: Int?

    var body: some View {
        let width = size.width
        let height = size.height
        let minSide = min(width, height)
        let center = CGPoint(x: width / 2.0, y: height / 2.0)
        let radius = (minSide - ringWidth) / 2.0
        let currentAngle = zoomToAngle(zoom)

        return Group {
            switch style {
            case .fullCircle:
                ZStack {
                    backgroundRing
                    activeArcFullCircle(trim: activeTrimValue(for: currentAngle))
                    tickMarksFull(center: center, radius: radius)
                    knobFull(size: size, center: center, currentAngle: currentAngle)
                    centerLabel(center: center, radius: radius)
                }
                .contentShape(Circle().inset(by: -ringWidth))
            case .semicircleBottom:
                ZStack(alignment: .bottom) {
                    semicircleGauge(center: center, radius: radius)
                    topCaptureOptionsOverlay()
                }
            }
        }
    }

    private var backgroundRing: some View {
        Circle()
            .stroke(Color.primary.opacity(0.15), lineWidth: ringWidth)
    }

    private func activeArcFullCircle(trim: CGFloat) -> some View {
        Circle()
            .trim(from: 0, to: trim)
            .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
            .rotationEffect(Angle(degrees: -90))
    }

    private struct TickMarkShape: Shape {
        let center: CGPoint
        let baseRadius: CGFloat
        let length: CGFloat
        let angle: Angle

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let a = angle.radians - .pi / 2.0
            let cosA = CGFloat(cos(a))
            let sinA = CGFloat(sin(a))
            let innerPoint = CGPoint(
                x: center.x + cosA * baseRadius,
                y: center.y + sinA * baseRadius
            )
            let outerPoint = CGPoint(
                x: center.x + cosA * (baseRadius + length),
                y: center.y + sinA * (baseRadius + length)
            )
            path.move(to: innerPoint)
            path.addLine(to: outerPoint)
            return path
        }
    }

    private func tickMarksFull(center: CGPoint, radius: CGFloat) -> some View {
        let tickLength: CGFloat = 12
        let tickThickness: CGFloat = 2
        let tickRadius: CGFloat = radius + ringWidth / 2.0

        return ForEach(majorTicks, id: \.self) { tick in
            let tickAngle = zoomToAngle(tick)
            TickMarkShape(center: center,
                          baseRadius: tickRadius,
                          length: tickLength,
                          angle: tickAngle)
                .stroke(Color.primary.opacity(0.7), lineWidth: tickThickness)
        }
    }

    private func knobFull(size: CGSize, center: CGPoint, currentAngle: Angle) -> some View {
        let pos = knobPosition(size, currentAngle)
        return Circle()
            .fill(Color.accentColor)
            .frame(width: knobRadius * 2.0, height: knobRadius * 2.0)
            .shadow(color: Color.black.opacity(0.3), radius: 3, x: 0, y: 2)
            .position(pos)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let angle = angleFrom(center, value.location)
                        let newZoom = angleToZoom(angle)
                        if newZoom != zoom {
                            zoom = newZoom
                            let idx = tickIndex(newZoom)
                            if lastTickIndex != idx {
                                lastTickIndex = idx
                                playHaptic()
                            }
                        }
                    }
                    .onEnded { _ in
                        lastTickIndex = nil
                    }
            )
    }

    private func centerLabel(center: CGPoint, radius: CGFloat) -> some View {
        let labelText = String(format: "%.1fx", zoom as NSNumber)
        return Text(labelText)
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .foregroundColor(Color.primary)
            .frame(width: radius * 1.2, height: radius * 1.2)
            .multilineTextAlignment(.center)
            .position(center)
    }

    private func activeTrimValue(for angle: Angle) -> CGFloat {
        switch style {
        case .fullCircle:
            let deg = angle.degrees
            let clamped = max(-90.0, min(270.0, deg))
            return CGFloat((clamped + 90.0) / 360.0)
        case .semicircleBottom:
            let deg = angle.degrees // [180..0]
            let clamped = max(0.0, min(180.0, deg))
            return CGFloat((180.0 - clamped) / 180.0)
        }
    }

    private func semicircleGauge(center: CGPoint, radius: CGFloat) -> some View {
        let base = Path { p in
            p.addArc(center: center,
                     radius: radius,
                     startAngle: .degrees(180),
                     endAngle: .degrees(0),
                     clockwise: false)
        }
        let currentAngle = zoomToAngle(zoom)
        // Active path trim for [180 -> 0]
        let trim = max(0, min(1, (180 - currentAngle.degrees) / 180))

        return ZStack(alignment: .bottom) {
            base.stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
            base.trim(from: 0, to: trim)
                .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
            tickMarksSemicircle(center: center, radius: radius)
            // Gesture area: a thick bottom arc shape
            base
                .stroke(Color.clear, lineWidth: max(ringWidth, 44))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let angle = bottomArcAngle(center, value.location)
                            let newZoom = angleToZoom(angle)
                            if newZoom != zoom {
                                zoom = newZoom
                                let idx = tickIndex(newZoom)
                                if lastTickIndex != idx {
                                    lastTickIndex = idx
                                    playHaptic()
                                }
                            }
                        }
                        .onEnded { _ in
                            lastTickIndex = nil
                        }
                )
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func tickMarksSemicircle(center: CGPoint, radius: CGFloat) -> some View {
        let tickLength: CGFloat = 12
        let tickThickness: CGFloat = 2
        let tickRadius: CGFloat = radius + ringWidth / 2.0
        return ForEach(majorTicks, id: \.self) { tick in
            let tickAngle = zoomToAngle(tick)
            TickMarkShape(center: center,
                          baseRadius: tickRadius,
                          length: tickLength,
                          angle: tickAngle)
                .stroke(Color.primary.opacity(0.7), lineWidth: tickThickness)
        }
    }

    @ViewBuilder
    private func topCaptureOptionsOverlay() -> some View {
        // Minimal top bar showing 24MP/48MP and HEIC/RAW toggles; host can hide if unused
        VStack {
            HStack(spacing: 12) {
                Picker("Resolution", selection: $resolution) {
                    ForEach(ResolutionSelection.allCases, id: \.self) { res in
                        Text(res.rawValue).tag(res)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)

                Picker("Format", selection: $format) {
                    ForEach(FormatSelection.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
    }
}
