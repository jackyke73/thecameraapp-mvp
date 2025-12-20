import SwiftUI
import CoreLocation

struct ContentView: View {
    @StateObject var cameraManager = CameraManager()
    @StateObject var locationManager = LocationManager()
    let smoother = CompassSmoother()
    
    @State var currentAdvice: DirectorAdvice?
    @State private var showMap = false
    
    // --- CHANGE 1: This is now @State so it can change! ---
    @State var targetLandmark = Landmark(
        name: "The Campanile",
        coordinate: CLLocationCoordinate2D(latitude: 37.8720, longitude: -122.2578)
    )
    
    // Helper to sync data with the Map
    // We bind directly to the State now
    var targetLandmarkBinding: Binding<MapLandmark> {
        Binding(
            get: {
                MapLandmark(name: targetLandmark.name, coordinate: targetLandmark.coordinate)
            },
            set: { newMapLandmark in
                // When Map updates, we update our main target
                targetLandmark = Landmark(name: newMapLandmark.name, coordinate: newMapLandmark.coordinate)
            }
        )
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Layer 1: Camera
                CameraPreview(cameraManager: cameraManager)
                    .ignoresSafeArea()
                
                // Layer 2: Floating Box
                if let advice = currentAdvice {
                    FloatingTargetView(
                        angleDiff: advice.turnAngle,
                        isLocked: abs(advice.turnAngle) < 3
                    )
                }
                
                // Layer 3: HUD
                VStack {
                    HStack {
                        Circle().fill(locationManager.permissionGranted ? Color.green : Color.red).frame(width: 8, height: 8)
                        Text(locationManager.permissionGranted ? "GPS ONLINE" : "OFFLINE")
                            .font(.caption2).bold().foregroundColor(.white)
                            .padding(4).background(.ultraThinMaterial).cornerRadius(4)
                        Spacer()
                    }
                    .padding(.top, 50).padding(.horizontal)
                    
                    Spacer()
                    
                    // Scope
                    if let advice = currentAdvice {
                        ScopeView(advice: advice).padding(.bottom, 50)
                    } else {
                        Text("Calibrating...").font(.headline).foregroundColor(.white).padding().background(.ultraThinMaterial).cornerRadius(15).padding(.bottom, 50)
                    }
                }
                
                // Layer 4: Map Button
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { showMap = true } label: {
                            Image(systemName: "map.fill")
                                .font(.title2).foregroundColor(.white).padding(15)
                                .background(.ultraThinMaterial).clipShape(Circle())
                                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                        }
                        .padding(.bottom, 50).padding(.trailing, 30)
                    }
                }
                
                // Layer 5: Calibration
                if locationManager.isInterferenceHigh {
                    CalibrationView().transition(.opacity).zIndex(100)
                }
            }
            // --- CHANGE 2: Pass the Binding ($) ---
            .navigationDestination(isPresented: $showMap) {
                MapScreen(locationManager: locationManager, landmark: targetLandmarkBinding)
            }
            .onReceive(locationManager.$heading) { _ in updateNavigationLogic() }
            .onReceive(locationManager.$location) { _ in updateNavigationLogic() }
        }
    }
    
    func updateNavigationLogic() {
        guard let userLoc = locationManager.location,
              let rawHeading = locationManager.heading?.trueHeading else { return }
        
        let smoothHeading = smoother.smooth(rawHeading)
        
        var newAdvice = PhotoDirector.guideToLandmark(
            userHeading: smoothHeading,
            userLocation: userLoc.coordinate,
            target: targetLandmark
        )
        
        if abs(newAdvice.turnAngle) < 3 {
            newAdvice = DirectorAdvice(message: newAdvice.message, icon: newAdvice.icon, isUrgent: newAdvice.isUrgent, lightingScore: newAdvice.lightingScore, turnAngle: 0)
        }
        
        withAnimation(.linear(duration: 0.1)) {
            self.currentAdvice = newAdvice
        }
    }
}

#Preview {
    ContentView()
}
