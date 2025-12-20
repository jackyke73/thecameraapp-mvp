import SwiftUI
import CoreLocation

struct ContentView: View {
    // 1. Initialize Engines
    @StateObject var cameraManager = CameraManager()
    @StateObject var locationManager = LocationManager()
    
    // Smoothing Engine
    let smoother = CompassSmoother()
    
    // UI State
    @State var currentAdvice: DirectorAdvice?
    @State private var showMap = false
    
    // 🎯 TARGET: The Campanile at UC Berkeley
    let targetLandmark = Landmark(
        name: "The Campanile",
        coordinate: CLLocationCoordinate2D(latitude: 37.8720, longitude: -122.2578)
    )
    
    // Helper to convert data for the Map Screen
    var targetLandmarkForMap: MapLandmark {
        MapLandmark(
            name: targetLandmark.name,
            coordinate: targetLandmark.coordinate
        )
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Layer 1: Camera Feed
                CameraPreview(cameraManager: cameraManager)
                    .ignoresSafeArea()
                
                // Layer 2: Floating Target Box
                if let advice = currentAdvice {
                    FloatingTargetView(
                        angleDiff: advice.turnAngle,
                        isLocked: abs(advice.turnAngle) < 3
                    )
                }
                
                // Layer 3: HUD
                VStack {
                    // Top Status Bar
                    HStack {
                        Circle()
                            .fill(locationManager.permissionGranted ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(locationManager.permissionGranted ? "GPS ONLINE" : "OFFLINE")
                            .font(.caption2).bold().foregroundColor(.white)
                            .padding(4).background(.ultraThinMaterial).cornerRadius(4)
                        Spacer()
                    }
                    .padding(.top, 50)
                    .padding(.horizontal)
                    
                    Spacer()
                    
                    // Bottom Scope
                    if let advice = currentAdvice {
                        ScopeView(advice: advice)
                            .padding(.bottom, 50)
                    } else {
                        Text("Calibrating Sensors...")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(15)
                            .padding(.bottom, 50)
                    }
                }
                
                // Layer 4: Map Button (Bottom Right)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            showMap = true
                        } label: {
                            Image(systemName: "map.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                                .padding(15)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                        }
                        .padding(.bottom, 50)
                        .padding(.trailing, 30)
                    }
                }
                
                // Layer 5: Calibration Overlay
                if locationManager.isInterferenceHigh {
                    CalibrationView()
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
            .navigationDestination(isPresented: $showMap) {
                MapScreen(locationManager: locationManager, landmark: targetLandmarkForMap)
            }
            // Reactive Logic
            .onReceive(locationManager.$heading) { _ in updateNavigationLogic() }
            .onReceive(locationManager.$location) { _ in updateNavigationLogic() }
        }
    }
    
    // The Brain Function
    func updateNavigationLogic() {
        guard let userLoc = locationManager.location,
              let rawHeading = locationManager.heading?.trueHeading else { return }
        
        let smoothHeading = smoother.smooth(rawHeading)
        
        var newAdvice = PhotoDirector.guideToLandmark(
            userHeading: smoothHeading,
            userLocation: userLoc.coordinate,
            target: targetLandmark
        )
        
        // Magnetic Snap
        if abs(newAdvice.turnAngle) < 3 {
            newAdvice = DirectorAdvice(
                message: newAdvice.message,
                icon: newAdvice.icon,
                isUrgent: newAdvice.isUrgent,
                lightingScore: newAdvice.lightingScore,
                turnAngle: 0
            )
        }
        
        withAnimation(.linear(duration: 0.1)) {
            self.currentAdvice = newAdvice
        }
    }
}

#Preview {
    ContentView()
}
