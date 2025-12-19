import Foundation
import CoreLocation

struct Landmark {
    let name: String
    let coordinate: CLLocationCoordinate2D
}

class LandmarkUtils {
    
    // 1. Calculate the "Bearing" (The angle from North to the Target)
    // Returns degrees (0-360)
    static func bearing(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> Double {
        let lat1 = source.latitude.toRadians
        let lon1 = source.longitude.toRadians
        
        let lat2 = destination.latitude.toRadians
        let lon2 = destination.longitude.toRadians
        
        let dLon = lon2 - lon1
        
        // The Formula
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let radians = atan2(y, x)
        
        // Convert to degrees (0-360)
        return (radians.toDegrees + 360).truncatingRemainder(dividingBy: 360)
    }
    
    // 2. Calculate Distance (in meters)
    static func distance(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> Double {
        let fromLoc = CLLocation(latitude: source.latitude, longitude: source.longitude)
        let toLoc = CLLocation(latitude: destination.latitude, longitude: destination.longitude)
        return fromLoc.distance(from: toLoc)
    }
}

// Helper extensions for clean math
extension Double {
    var toRadians: Double { self * .pi / 180 }
    var toDegrees: Double { self * 180 / .pi }
}
