import SwiftUI
import MapKit
import CoreLocation

// A simple data model for the pin
struct MapLandmark: Identifiable {
    let id = UUID()
    let name: String
    let coordinate: CLLocationCoordinate2D
}

struct MapScreen: View {
    @ObservedObject var locationManager: LocationManager
    let landmark: MapLandmark

    // 1. CONTROL THE CAMERA
    // ".userLocation(fallback: .automatic)" makes it follow you immediately
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        ZStack {
            // 2. THE MODERN MAP
            Map(position: $position) {
                
                // Draw the User (The Blue Dot)
                UserAnnotation()
                
                // Draw the Target (Red Pin)
                Annotation(landmark.name, coordinate: landmark.coordinate) {
                    ZStack {
                        Circle()
                            .fill(.red)
                            .frame(width: 20, height: 20)
                            .shadow(radius: 5)
                        
                        Image(systemName: "camera.fill")
                            .font(.caption2)
                            .foregroundColor(.white)
                    }
                }
            }
            // 3. ENABLE "GOOGLE EARTH" MODE
            // .hybrid = Satellite + Roads
            // elevation: .realistic = 3D Hills/Buildings
            .mapStyle(.hybrid(elevation: .realistic))
            
            // 4. ADD STANDARD CONTROLS (Compass, GPS Button)
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
                MapPitchToggle() // Allows 3D tilting
            }
            
            // 5. DISTANCE OVERLAY
            VStack {
                HStack {
                    Image(systemName: "location.fill")
                        .foregroundColor(.yellow)
                    
                    if let userLoc = locationManager.location {
                        let distance = userLoc.distance(from: CLLocation(latitude: landmark.coordinate.latitude, longitude: landmark.coordinate.longitude))
                        Text("Distance: \(Int(distance))m")
                            .font(.headline)
                            .bold()
                            .foregroundColor(.white)
                    } else {
                        Text("Locating...")
                            .foregroundColor(.white)
                    }
                    
                    Spacer()
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(15)
                .padding()
                
                Spacer()
            }
        }
        .navigationTitle(landmark.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Force the compass to start updating so the map rotates
            locationManager.startUpdates()
        }
    }
}

#Preview {
    // Dummy preview data
    MapScreen(
        locationManager: LocationManager(),
        landmark: MapLandmark(name: "Test Target", coordinate: CLLocationCoordinate2D(latitude: 37.8720, longitude: -122.2578))
    )
}
