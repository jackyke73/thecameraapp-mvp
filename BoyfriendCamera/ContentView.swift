import SwiftUI
import CoreLocation

enum AspectRatio: String, CaseIterable {
    case fourThree = "4:3"; case sixteenNine = "16:9"; case square = "1:1"
    var value: CGFloat {
        switch self { case .fourThree: return 4.0/3.0; case .sixteenNine: return 16.0/9.0; case .square: return 1.0 }
    }
}

struct ContentView: View {
    @StateObject var cameraManager = CameraManager()
    @StateObject var locationManager = LocationManager()
    let smoother = CompassSmoother()
    
    @State var currentAdvice: DirectorAdvice?
    @State private var showMap = false
    @State private var showFlashAnimation = false
    @State private var isCapturing = false
    @State private var isZoomDialVisible = false
    @State private var currentAspectRatio: AspectRatio = .fourThree
    
    // SETTINGS STATES
    @State private var showSettings = false
    @State private var exposureValue: Float = 0.0
    @State private var whiteBalanceValue: Float = 5500.0
    @State private var focusValue: Float = 0.5
    @State private var torchValue: Float = 0.0
    
    // NEW STATES
    @State private var isGridEnabled = false
    @State private var isTimerEnabled = false
    
    @State var targetLandmark = Landmark(name: "The Campanile", coordinate: CLLocationCoordinate2D(latitude: 37.8720, longitude: -122.2578))
    var targetLandmarkBinding: Binding<MapLandmark> {
        Binding(get: { MapLandmark(name: targetLandmark.name, coordinate: targetLandmark.coordinate) }, set: { new in targetLandmark = Landmark(name: new.name, coordinate: new.coordinate) })
    }
    @State private var startZoomValue: CGFloat = 1.0
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                // 1. CAMERA & GRID
                GeometryReader { geo in
                    let ratio = currentAspectRatio.value
                    let w = geo.size.width
                    let h = w * ratio
                    
                    ZStack {
                        CameraPreview(cameraManager: cameraManager)
                        
                        // NEW: Grid Overlay
                        if isGridEnabled {
                            GridOverlay().stroke(Color.white.opacity(0.3), lineWidth: 1)
                        }
                    }
                    .frame(width: w, height: h)
                    .clipped()
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .gesture(
                        MagnificationGesture().onChanged { val in cameraManager.setZoomInstant(cameraManager.currentZoomFactor * val) }
                    )
                }
                .ignoresSafeArea()
                
                // 2. OVERLAYS
                if let advice = currentAdvice {
                    FloatingTargetView(angleDiff: advice.turnAngle, isLocked: abs(advice.turnAngle) < 3)
                }
                
                // 3. UI CONTROLS
                VStack {
                    // Top Bar
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(locationManager.permissionGranted ? Color.green : Color.red).frame(width: 6, height: 6)
                            Text(locationManager.permissionGranted ? "GPS" : "NO GPS").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Color.black.opacity(0.4)).cornerRadius(12)
                        
                        Spacer()
                        
                        // Settings Button
                        Button { withAnimation { showSettings.toggle() } } label: {
                            Image(systemName: "slider.horizontal.3").font(.headline)
                                .foregroundColor(showSettings ? .yellow : .white)
                                .padding(8).background(.ultraThinMaterial).clipShape(Circle())
                        }
                        
                        Button { toggleAspectRatio() } label: {
                            Text(currentAspectRatio.rawValue).font(.footnote.bold()).foregroundColor(.white).padding(8).background(.ultraThinMaterial).clipShape(Capsule())
                        }
                    }
                    .padding(.top, 50).padding(.horizontal)
                    
                    // --- SETTINGS PANEL ---
                    if showSettings {
                        VStack(spacing: 15) {
                            // Toggles Row
                            HStack(spacing: 20) {
                                ToggleButton(icon: "grid", label: "Grid", isOn: $isGridEnabled)
                                ToggleButton(icon: "timer", label: "3s Timer", isOn: $isTimerEnabled)
                            }
                            
                            // Exposure
                            HStack {
                                Image(systemName: "sun.max.fill").font(.caption).foregroundColor(.white)
                                Slider(value: $exposureValue, in: -2...2)
                                    .tint(.yellow)
                                    .onChange(of: exposureValue) { _, val in cameraManager.setExposure(ev: val) }
                                Text(String(format: "%.1f", exposureValue)).font(.caption.monospacedDigit()).foregroundColor(.white).frame(width: 30)
                            }
                            
                            // WB (Conditional)
                            if cameraManager.isWBSupported {
                                HStack {
                                    Image(systemName: "thermometer").font(.caption).foregroundColor(.white)
                                    Slider(value: $whiteBalanceValue, in: 3000...8000)
                                        .tint(.orange)
                                        .onChange(of: whiteBalanceValue) { _, val in cameraManager.setWhiteBalance(kelvin: val) }
                                    Text("\(Int(whiteBalanceValue))K").font(.caption.monospacedDigit()).foregroundColor(.white).frame(width: 45)
                                }
                            }
                            
                            // Focus (Conditional)
                            if cameraManager.isFocusSupported {
                                HStack {
                                    Image(systemName: "flower").font(.caption).foregroundColor(.white)
                                    Slider(value: $focusValue, in: 0.0...1.0)
                                        .tint(.cyan)
                                        .onChange(of: focusValue) { _, val in cameraManager.setLensPosition(val) }
                                    Image(systemName: "mountain.2").font(.caption).foregroundColor(.white)
                                }
                            }
                            
                            // Reset
                            Button("Reset All") {
                                exposureValue = 0; whiteBalanceValue = 5500; focusValue = 0.5; torchValue = 0.0
                                cameraManager.resetSettings()
                            }
                            .font(.caption.bold()).foregroundColor(.black).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.yellow).cornerRadius(8)
                        }
                        .padding().background(.ultraThinMaterial).cornerRadius(15).padding(.horizontal)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    
                    Spacer()
                    
                    if let advice = currentAdvice {
                        ScopeView(advice: advice).padding(.bottom, 10)
                    }
                    
                    // --- ZOOM CONTROLS ---
                    ZStack(alignment: .bottom) {
                        if isZoomDialVisible {
                            ArcZoomDial(currentZoom: cameraManager.currentZoomFactor, minZoom: cameraManager.minZoomFactor, maxZoom: cameraManager.maxZoomFactor, presets: cameraManager.zoomButtons)
                                .transition(.opacity).zIndex(1)
                        }
                        if !isZoomDialVisible {
                            HStack(spacing: 20) {
                                ForEach(cameraManager.zoomButtons, id: \.self) { preset in
                                    ZoomBubble(label: preset == 0.5 ? ".5" : String(format: "%.0f", preset), isSelected: abs(cameraManager.currentZoomFactor - preset) < 0.1)
                                        .onTapGesture { withAnimation { cameraManager.setZoomSmooth(preset) } }
                                }
                            }
                            .padding(.bottom, 20).transition(.opacity).zIndex(2)
                        }
                    }
                    .frame(height: 100).contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !isZoomDialVisible { withAnimation { isZoomDialVisible = true }; startZoomValue = cameraManager.currentZoomFactor }
                                let delta = -value.translation.width / 150.0
                                let rawZoom = startZoomValue * pow(2, delta)
                                let clampedZoom = max(cameraManager.minZoomFactor, min(cameraManager.maxZoomFactor, rawZoom))
                                cameraManager.setZoomInstant(clampedZoom)
                            }
                            .onEnded { _ in
                                startZoomValue = cameraManager.currentZoomFactor
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { withAnimation { isZoomDialVisible = false } }
                            }
                    )
                    
                    // BOTTOM SHUTTER
                    HStack {
                        Button { showMap = true } label: {
                            Image(systemName: "map.fill").font(.title3).foregroundColor(.white).frame(width: 44, height: 44).background(.ultraThinMaterial).clipShape(Circle())
                        }
                        Spacer()
                        Button { takePhoto() } label: {
                            ZStack {
                                Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                                Circle().fill(.white).frame(width: 62, height: 62).scaleEffect(isCapturing ? 0.85 : 1.0)
                            }
                        }
                        Spacer()
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .padding(.horizontal, 40).padding(.bottom, 40)
                }
                
                // --- FULL SCREEN OVERLAYS ---
                if showFlashAnimation { Color.white.ignoresSafeArea().transition(.opacity).zIndex(100) }
                
                // NEW: Timer Countdown Overlay
                if cameraManager.isTimerRunning {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    Text("\(cameraManager.timerCount)")
                        .font(.system(size: 100, weight: .bold))
                        .foregroundColor(.white)
                        .transition(.scale.combined(with: .opacity))
                        .zIndex(200)
                }
            }
            .navigationDestination(isPresented: $showMap) {
                MapScreen(locationManager: locationManager, landmark: targetLandmarkBinding)
            }
            .onReceive(locationManager.$heading) { _ in updateNavigationLogic() }
            .onReceive(locationManager.$location) { _ in updateNavigationLogic() }
            .onReceive(cameraManager.captureDidFinish) { _ in isCapturing = false }
        }
    }
    
    // Actions
    func toggleAspectRatio() {
        let allCases = AspectRatio.allCases
        if let currentIndex = allCases.firstIndex(of: currentAspectRatio) {
            let nextIndex = (currentIndex + 1) % allCases.count
            currentAspectRatio = allCases[nextIndex]
        }
    }
    func takePhoto() {
        if !isTimerEnabled {
            // Instant Flash
            isCapturing = true
            withAnimation(.easeOut(duration: 0.1)) { showFlashAnimation = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation { showFlashAnimation = false } }
        }
        
        cameraManager.capturePhoto(location: locationManager.location, aspectRatioValue: currentAspectRatio.value, useTimer: isTimerEnabled)
    }
    func updateNavigationLogic() {
        guard let userLoc = locationManager.location, let rawHeading = locationManager.heading?.trueHeading else { return }
        let smooth = smoother.smooth(rawHeading)
        let advice = PhotoDirector.guideToLandmark(userHeading: smooth, userLocation: userLoc.coordinate, target: targetLandmark)
        withAnimation { currentAdvice = advice }
    }
}

// Subviews
struct ZoomBubble: View {
    let label: String; let isSelected: Bool
    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.5))
            if isSelected { Circle().stroke(.yellow, lineWidth: 1) }
            Text(label + "x").font(.system(size: 12, weight: .bold)).foregroundColor(isSelected ? .yellow : .white)
        }
        .frame(width: 38, height: 38)
    }
}

struct ToggleButton: View {
    let icon: String; let label: String; @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack {
                Image(systemName: icon)
                Text(label).font(.caption.bold())
            }
            .foregroundColor(isOn ? .black : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(isOn ? Color.yellow : Color.black.opacity(0.5))
            .cornerRadius(8)
        }
    }
}

// 3x3 Grid Shape
struct GridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Vertical lines
        path.move(to: CGPoint(x: rect.width / 3, y: 0)); path.addLine(to: CGPoint(x: rect.width / 3, y: rect.height))
        path.move(to: CGPoint(x: 2 * rect.width / 3, y: 0)); path.addLine(to: CGPoint(x: 2 * rect.width / 3, y: rect.height))
        // Horizontal lines
        path.move(to: CGPoint(x: 0, y: rect.height / 3)); path.addLine(to: CGPoint(x: rect.width, y: rect.height / 3))
        path.move(to: CGPoint(x: 0, y: 2 * rect.height / 3)); path.addLine(to: CGPoint(x: rect.width, y: 2 * rect.height / 3))
        return path
    }
}
