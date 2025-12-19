import SwiftUI
import CoreLocation

struct ContentView: View {
    @StateObject var cameraManager = CameraManager()
    @StateObject var locationManager = LocationManager() // <--- NEW SENSOR
    
    // Simple state to hold the sun result
    @State var sunInfo: String = "Waiting for GPS..."
    
    var body: some View {
        ZStack {
            // 1. Camera Feed
            CameraPreview(cameraManager: cameraManager)
                .ignoresSafeArea()
            
            // 2. The HUD
            VStack {
                // Top Status Bar
                HStack {
                    // Person Indicator
                    Circle()
                        .fill(cameraManager.isPersonDetected ? Color.green : Color.red)
                        .frame(width: 15, height: 15)
                    
                    Text(cameraManager.isPersonDetected ? "HUMAN" : "EMPTY")
                        .font(.caption)
                        .bold()
                        .foregroundColor(cameraManager.isPersonDetected ? .green : .red)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                    
                    Spacer()
                    
                    // NEW: Sun Indicator
                    Text(sunInfo)
                        .font(.caption)
                        .bold()
                        .foregroundColor(.yellow)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                }
                .padding(.top, 50)
                .padding(.horizontal)
                
                Spacer()
            }
        }
        // This is the "Brain" Logic
        .onReceive(locationManager.$location) { newLocation in
            guard let loc = newLocation else { return }
            
            // MATH TIME: Run the calculation every time we move
            let sunPos = SunCalculator.compute(date: Date(), coordinate: loc.coordinate)
            
            // Format the result nicely
            let az = Int(sunPos.azimuth)
            let el = Int(sunPos.elevation)
            let status = sunPos.isGoldenHour ? "✨ GOLDEN" : "☀️ NORMAL"
            
            self.sunInfo = "\(status) | Az: \(az)° El: \(el)°"
        }
    }
}
