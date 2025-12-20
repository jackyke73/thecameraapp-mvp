import SwiftUI
import CoreLocation

struct ContentView: View {
    // 1. Initialize our Engines (Sensors)
    @StateObject var cameraManager = CameraManager()
    @StateObject var locationManager = LocationManager()
    
    @State private var showMap = false
    
    
    
    // 3. DEFINE YOUR TARGET LANDMARK HERE
    // Example: The Campanile at UC Berkeley
    let targetLandmark = Landmark(
        name: "The Campanile",
        coordinate: CLLocationCoordinate2D(latitude: 37.8720, longitude: -122.2578)
    )
    
    
    var targetLandmarkForMap: MapLandmark {
        MapLandmark(
            name: targetLandmark.name,
            coordinate: targetLandmark.coordinate
        )
    }
    
    
    // NEW: The Smoothing Engine
    let smoother = CompassSmoother()
    
    // 2. State to hold the dynamic advice from the Brain
    @State var currentAdvice: DirectorAdvice?
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Layer 1: The Real-World Camera Feed
                CameraPreview(cameraManager: cameraManager)
                    .ignoresSafeArea()
                
                // Layer 2: The UI
                VStack {
                    // Top Status Bar (GPS Debug info)
                    HStack {
                        Circle()
                            .fill(locationManager.permissionGranted ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(locationManager.permissionGranted ? "GPS ACTIVE" : "NO GPS")
                            .font(.caption2)
                            .bold()
                            .foregroundColor(.white)
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(4)
                        Spacer()
                    }
                    .padding(.top, 50)
                    .padding(.horizontal)
                    
                    Spacer()
                    
                    // Bottom Layer: The Director's Scope
                    if let advice = currentAdvice {
                        ScopeView(advice: advice)
                            .padding(.bottom, 50)
                    } else {
                        // Loading State
                        Text("Calibrating Sensors...")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(15)
                            .padding(.bottom, 50)
                    }
                }
                
            }
            // REACTIVE LOGIC: Run this whenever the phone moves or turns
            .onReceive(locationManager.$heading) { _ in
                updateNavigationLogic()
            }
            .onReceive(locationManager.$location) { _ in
                updateNavigationLogic()
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .bottom) {
                HStack {
                    Spacer()
                    Button {
                        showMap = true
                    } label: {
                        Image(systemName: "map")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    
                }
                .padding(.bottom, 20)
                .padding(.horizontal)
                
            }
            .navigationDestination(isPresented: $showMap) {
                MapScreen(locationManager: locationManager, landmark: targetLandmarkForMap)
                
            }
        }
    }
    
    // The Brain Function
    private func updateNavigationLogic() {
        guard let userLoc = locationManager.location,
              let rawHeading = locationManager.heading?.trueHeading else { return }
        
        // 1. SMOOTH THE DATA
        let smoothHeading = smoother.smooth(rawHeading)
        
        // 2. Ask the Director for advice using the SMOOTHED heading
        let newAdvice = PhotoDirector.guideToLandmark(
            userHeading: smoothHeading,
            userLocation: userLoc.coordinate,
            target: targetLandmark
        )
        
        // 3. Update the UI
        withAnimation(.linear(duration: 0.1)) {
            self.currentAdvice = newAdvice
        }
    }
}


#Preview {
    ContentView()
}

