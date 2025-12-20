import SwiftUI
import CoreLocation
import Darwin

// Helper for Aspect Ratios
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

struct ContentView: View {
    @StateObject var cameraManager = CameraManager()
    
    // MARK: - Device / Zoom Presets
    struct DeviceZoomPresets {
        // Lightweight device identifier lookup (e.g., "iPhone17,1")
        private static func deviceIdentifier() -> String {
            var systemInfo = utsname()
            uname(&systemInfo)
            let mirror = Mirror(reflecting: systemInfo.machine)
            let identifier = mirror.children.reduce("") { identifier, element in
                guard let value = element.value as? Int8, value != 0 else { return identifier }
                return identifier + String(UnicodeScalar(UInt8(value)))
            }
            return identifier
        }

        // Known families that include an ultra-wide camera supporting 0.5x (iPhone 11 and newer, SE excluded)
        static func supportsUltraWide() -> Bool {
            let id = deviceIdentifier()
            // Common patterns; this isn't exhaustive but covers modern devices including iPhone 12–17 and Pro/Pro Max lines.
            // Examples: iPhone11,8 (XR - no ultra-wide), iPhone12,1 (11), iPhone13,4 (12 Pro Max), iPhone16,1/2 (15), iPhone17,x (16), iPhone18,x (17)
            // We conservatively include from iPhone12,1 (iPhone 11) upward, excluding iPhone SE identifiers.
            if id.contains("iPhone SE") { return false }
            // Parse major version from pattern "iPhone<major>,<minor>"
            if id.hasPrefix("iPhone") {
                let parts = id.dropFirst("iPhone".count).split(separator: ",")
                if let majorPart = parts.first, let major = Int(majorPart) {
                    // iPhone 11 (12,1) and newer support ultra‑wide
                    return major >= 12
                }
            }
            // Default to true on simulators or unknown newer models
            return true
        }

        static func availableZoomFactors() -> [CGFloat] {
            // Desired Apple-style presets
            var desired: [CGFloat] = [1.0, 2.0, 4.0, 8.0]
            if supportsUltraWide() {
                desired.insert(0.5, at: 0)
            }
            return desired
        }
    }

    // Dynamic zoom presets based on device and camera capability
    @State private var zoomPresets: [CGFloat] = DeviceZoomPresets.availableZoomFactors()
    
    @StateObject var locationManager = LocationManager()
    let smoother = CompassSmoother()
    
    @State var currentAdvice: DirectorAdvice?
    @State private var showMap = false
    @State private var showFlashAnimation = false
    @State private var isCapturing = false
    @State private var isZoomDialVisible = false
    
    // Added state for zoom dial presentation and haptic tracking
    @State private var isZoomDialPresented = false
    @State private var lastHapticTick: CGFloat = -1
    
    // UI State
    @State private var currentAspectRatio: AspectRatio = .fourThree
    
    // Target
    @State var targetLandmark = Landmark(name: "The Campanile", coordinate: CLLocationCoordinate2D(latitude: 37.8720, longitude: -122.2578))
    var targetLandmarkBinding: Binding<MapLandmark> {
        Binding(get: { MapLandmark(name: targetLandmark.name, coordinate: targetLandmark.coordinate) }, set: { new in targetLandmark = Landmark(name: new.name, coordinate: new.coordinate) })
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                // Configure zoom presets based on camera capability
                Color.clear.frame(width: 0, height: 0)
                    .onAppear {
                        let minZ = cameraManager.minZoomFactor
                        let maxZ = cameraManager.maxZoomFactor
                        // Keep original desired order, but filter to supported range
                        let desired = DeviceZoomPresets.availableZoomFactors()
                        // Preserve 0.5x if the device supports ultra-wide, even if current camera's minZ > 0.5
                        var filtered: [CGFloat] = []
                        for z in desired {
                            if abs(z - 0.5) < 0.001 {
                                if DeviceZoomPresets.supportsUltraWide() {
                                    filtered.append(0.5)
                                }
                            } else if z >= minZ && z <= maxZ {
                                filtered.append(z)
                            }
                        }
                        if !filtered.isEmpty {
                            zoomPresets = filtered
                        } else {
                            // Fallback to at least 1x within range
                            let fallback: [CGFloat] = [1.0].filter { $0 >= minZ && $0 <= maxZ }
                            zoomPresets = fallback.isEmpty ? [minZ] : fallback
                        }
                    }
                
                // 1. CAMERA (Masked to Aspect Ratio)
                GeometryReader { geo in
                    let ratio = currentAspectRatio.value
                    let w = geo.size.width
                    // Height calculation: If 16:9 (ratio 1.77), height = w * 1.77.
                    // If 4:3 (ratio 1.33), height = w * 1.33.
                    let h = w * ratio
                    
                    CameraPreview(cameraManager: cameraManager)
                        .frame(width: w, height: h)
                        .clipped() // This visually crops the preview
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { val in cameraManager.setZoom(cameraManager.currentZoomFactor * val) }
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
                        // GPS Status
                        HStack(spacing: 6) {
                            Circle().fill(locationManager.permissionGranted ? Color.green : Color.red).frame(width: 6, height: 6)
                            Text(locationManager.permissionGranted ? "GPS" : "NO GPS").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Color.black.opacity(0.4)).cornerRadius(12)
                        
                        Spacer()
                        
                        // Aspect Ratio Toggle
                        Button {
                            toggleAspectRatio()
                        } label: {
                            Text(currentAspectRatio.rawValue)
                                .font(.footnote.bold()).foregroundColor(.white)
                                .padding(8).background(.ultraThinMaterial).clipShape(Capsule())
                        }
                    }
                    .padding(.top, 50).padding(.horizontal)
                    
                    Spacer()
                    
                    // Advice Pill
                    if let advice = currentAdvice {
                        ScopeView(advice: advice).padding(.bottom, 10)
                    }
                    
                    // --- ZOOM CONTROLS ---
                    VStack(spacing: 0) {
                        if isZoomDialVisible {
                            Slider(value: Binding(get: { cameraManager.currentZoomFactor }, set: { cameraManager.setZoom($0) }), in: cameraManager.minZoomFactor...cameraManager.maxZoomFactor)
                                .tint(.yellow)
                                .padding(.horizontal, 40)
                                .background(Capsule().fill(Color.black.opacity(0.4)).frame(height: 24))
                                .padding(.bottom, 10)
                        }
                        
                        // Dynamic Buttons (Apple-style segmented zoom selector)
                        HStack(spacing: 12) {
                            ForEach(zoomPresets, id: \.self) { preset in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        cameraManager.setZoom(preset)
                                    }
                                } label: {
                                    ZStack {
                                        Capsule()
                                            .fill(Color.black.opacity(0.5))
                                        Capsule()
                                            .stroke(abs(cameraManager.currentZoomFactor - preset) < 0.05 ? Color.yellow : Color.white.opacity(0.25), lineWidth: abs(cameraManager.currentZoomFactor - preset) < 0.05 ? 1.5 : 1)
                                        Text(labelForZoom(preset))
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .foregroundColor(abs(cameraManager.currentZoomFactor - preset) < 0.05 ? .yellow : .white)
                                            .padding(.horizontal, 10)
                                    }
                                    .frame(height: 32)
                                }
                                .buttonStyle(.plain)
                                .simultaneousGesture(
                                    LongPressGesture().onEnded { _ in
                                        withAnimation { isZoomDialPresented = true }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                    
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
                
                // Display Zoom Dial overlay when presented
                if isZoomDialPresented {
                    ZStack {
                        Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { withAnimation { isZoomDialPresented = false } }
                        ZoomDialView(
                            zoom: Binding(get: { cameraManager.currentZoomFactor }, set: { cameraManager.setZoom($0) }),
                            minZoom: cameraManager.minZoomFactor,
                            maxZoom: cameraManager.maxZoomFactor,
                            majorTicks: zoomPresets
                        )
                        .frame(width: 260, height: 260)
                        .transition(.scale.combined(with: .opacity))
                    }
                    .zIndex(200)
                }
                
                // Animations
                if showFlashAnimation { Color.white.ignoresSafeArea().transition(.opacity).zIndex(100) }
            }
            .navigationDestination(isPresented: $showMap) {
                MapScreen(locationManager: locationManager, landmark: targetLandmarkBinding)
            }
            .onReceive(locationManager.$heading) { _ in updateNavigationLogic() }
            .onReceive(locationManager.$location) { _ in updateNavigationLogic() }
            .onReceive(cameraManager.captureDidFinish) { _ in isCapturing = false }
            .onChange(of: isZoomDialVisible) { _, visible in
                if visible { DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { withAnimation { isZoomDialVisible = false } } }
            }
        }
    }
    
    // MARK: - Helpers
    func labelForZoom(_ value: CGFloat) -> String {
        if abs(value - 0.5) < 0.01 { return ".5x" }
        if abs(value.rounded() - value) < 0.01 { return "\(Int(value))x" }
        // Show one decimal if needed
        return String(format: "%.1fx", value)
    }
    
    // MARK: - Actions
    
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
        
        // PASS THE RATIO TO THE MANAGER
        cameraManager.capturePhoto(location: locationManager.location, aspectRatioValue: currentAspectRatio.value)
    }
    
    func updateNavigationLogic() {
        guard let userLoc = locationManager.location, let rawHeading = locationManager.heading?.trueHeading else { return }
        let smooth = smoother.smooth(rawHeading)
        let advice = PhotoDirector.guideToLandmark(userHeading: smooth, userLocation: userLoc.coordinate, target: targetLandmark)
        withAnimation { currentAdvice = advice }
    }
}

