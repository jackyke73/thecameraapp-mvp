import SwiftUI
import CoreLocation

// --- 1. Enum ---
enum AspectRatio: String, CaseIterable {
    case fourThree = "4:3"
    case sixteenNine = "16:9"
    case square = "1:1"
    
    var value: CGFloat {
        switch self {
        case .fourThree: return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .square: return 1.0
        }
    }
}

// --- 2. Main View ---
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
    
    @State var targetLandmark = Landmark(name: "The Campanile", coordinate: CLLocationCoordinate2D(latitude: 37.8720, longitude: -122.2578))
    
    var targetLandmarkBinding: Binding<MapLandmark> {
        Binding(get: { MapLandmark(name: targetLandmark.name, coordinate: targetLandmark.coordinate) }, set: { new in targetLandmark = Landmark(name: new.name, coordinate: new.coordinate) })
    }
    
    // Zoom Gesture State
    @State private var startZoomValue: CGFloat = 1.0
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                // 1. CAMERA
                GeometryReader { geo in
                    let ratio = currentAspectRatio.value
                    let w = geo.size.width
                    let h = w * ratio
                    
                    CameraPreview(cameraManager: cameraManager)
                        .frame(width: w, height: h)
                        .clipped()
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { val in
                                    // Use Instant Zoom for Pinch
                                    let newZoom = cameraManager.currentZoomFactor * val
                                    cameraManager.setZoomInstant(newZoom)
                                }
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
                        
                        Button { toggleAspectRatio() } label: {
                            Text(currentAspectRatio.rawValue).font(.footnote.bold()).foregroundColor(.white).padding(8).background(.ultraThinMaterial).clipShape(Capsule())
                        }
                    }
                    .padding(.top, 50).padding(.horizontal)
                    
                    Spacer()
                    
                    if let advice = currentAdvice {
                        ScopeView(advice: advice).padding(.bottom, 10)
                    }
                    
                    // --- UNIFIED ZOOM CONTROL AREA ---
                    ZStack(alignment: .bottom) {
                        
                        // A. The Dial (Visible ONLY when dragging)
                        if isZoomDialVisible {
                            ArcZoomDial(
                                currentZoom: cameraManager.currentZoomFactor,
                                minZoom: cameraManager.minZoomFactor,
                                maxZoom: cameraManager.maxZoomFactor,
                                presets: cameraManager.zoomButtons
                            )
                            // Transition: Fade In/Out
                            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                            .zIndex(2)
                        }
                        
                        // B. The Buttons (Visible ONLY when NOT dragging)
                        if !isZoomDialVisible {
                            HStack(spacing: 20) {
                                ForEach(cameraManager.zoomButtons, id: \.self) { preset in
                                    ZoomBubble(
                                        label: preset == 0.5 ? ".5" : String(format: "%.0f", preset),
                                        isSelected: abs(cameraManager.currentZoomFactor - preset) < 0.1
                                    )
                                    .onTapGesture {
                                        // Tap logic: Just jump, don't show dial
                                        withAnimation { cameraManager.setZoomSmooth(preset) }
                                    }
                                }
                            }
                            .padding(.bottom, 30) // Align visually with where dial appears
                            // Transition: Fade In/Out
                            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                            .zIndex(1)
                        }
                    }
                    .frame(height: 100) // Fixed height to prevent layout jumps
                    // --- MASTER SCROLL GESTURE ---
                    .contentShape(Rectangle()) // Capture touches even in empty space
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // 1. Start Drag: Hide Buttons, Show Dial
                                if !isZoomDialVisible {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isZoomDialVisible = true
                                    }
                                    startZoomValue = cameraManager.currentZoomFactor
                                }
                                
                                // 2. Calculate Logic
                                let delta = -value.translation.width / 150.0
                                let rawZoom = startZoomValue * pow(2, delta)
                                let clampedZoom = max(cameraManager.minZoomFactor, min(cameraManager.maxZoomFactor, rawZoom))
                                
                                // 3. Instant Zoom Update
                                cameraManager.setZoomInstant(clampedZoom)
                            }
                            .onEnded { _ in
                                // 4. End Drag: Wait a moment, then Hide Dial, Show Buttons
                                startZoomValue = cameraManager.currentZoomFactor
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        isZoomDialVisible = false
                                    }
                                }
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
                
                if showFlashAnimation { Color.white.ignoresSafeArea().transition(.opacity).zIndex(100) }
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
        isCapturing = true
        withAnimation(.easeOut(duration: 0.1)) { showFlashAnimation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation { showFlashAnimation = false } }
        cameraManager.capturePhoto(location: locationManager.location, aspectRatioValue: currentAspectRatio.value)
    }
    func updateNavigationLogic() {
        guard let userLoc = locationManager.location, let rawHeading = locationManager.heading?.trueHeading else { return }
        let smooth = smoother.smooth(rawHeading)
        let advice = PhotoDirector.guideToLandmark(userHeading: smooth, userLocation: userLoc.coordinate, target: targetLandmark)
        withAnimation { currentAdvice = advice }
    }
}

// --- 3. Helper View ---
struct ZoomBubble: View {
    let label: String
    let isSelected: Bool
    
    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.5))
            if isSelected { Circle().stroke(.yellow, lineWidth: 1) }
            Text(label + "x")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(isSelected ? .yellow : .white)
        }
        .frame(width: 38, height: 38)
    }
}
