import SwiftUI
import CoreLocation

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
                    
                    // --- ZOOM CONTROLS ---
                    VStack(spacing: 0) {
                        if isZoomDialVisible {
                            Slider(value: Binding(get: { cameraManager.currentZoomFactor }, set: { cameraManager.setZoom($0) }), in: cameraManager.minZoomFactor...cameraManager.maxZoomFactor)
                                .tint(.yellow)
                                .padding(.horizontal, 40)
                                .background(Capsule().fill(Color.black.opacity(0.4)).frame(height: 24))
                                .padding(.bottom, 10)
                        }
                        
                        // FIXED: Render exactly what is in the zoomButtons array
                        HStack(spacing: 20) {
                            ForEach(cameraManager.zoomButtons, id: \.self) { preset in
                                Button {
                                    withAnimation { cameraManager.setZoom(preset) }
                                } label: {
                                    ZStack {
                                        Circle().fill(Color.black.opacity(0.5))
                                        if abs(cameraManager.currentZoomFactor - preset) < 0.1 { Circle().stroke(.yellow, lineWidth: 1) }
                                        
                                        // LABEL LOGIC: 0.5 -> ".5", 1.0 -> "1", 2.0 -> "2"
                                        Text(preset == 0.5 ? ".5" : String(format: "%.0f", preset))
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(abs(cameraManager.currentZoomFactor - preset) < 0.1 ? .yellow : .white)
                                    }
                                    .frame(width: 38, height: 38)
                                }
                                .simultaneousGesture(LongPressGesture().onEnded { _ in withAnimation { isZoomDialVisible = true } })
                            }
                        }
                        .padding(.bottom, 20)
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
