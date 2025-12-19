import Foundation
import CoreLocation

struct DirectorAdvice {
    let message: String
    let icon: String
    let isUrgent: Bool
    let lightingScore: Int
    let turnAngle: Double // NEW: The exact number of degrees to turn
}

class PhotoDirector {
    
    // GUIDE TO LANDMARK (The Navigation Logic)
    static func guideToLandmark(
            userHeading: Double,
            userLocation: CLLocationCoordinate2D,
            target: Landmark
        ) -> DirectorAdvice {
            
            let targetBearing = LandmarkUtils.bearing(from: userLocation, to: target.coordinate)
            var diff = targetBearing - userHeading
            
            // Normalize
            if diff > 180 { diff -= 360 }
            if diff < -180 { diff += 360 }
            
            let distance = LandmarkUtils.distance(from: userLocation, to: target.coordinate)
            let distString = distance > 1000 ? String(format: "%.1fkm", distance/1000) : String(format: "%.0fm", distance)
            
            // LOGIC: Is the target in front of us?
            // If diff is between -45 and +45, it's "On Screen"
            let isOnScreen = abs(diff) < 45
            
            if isOnScreen {
                // Precise aiming mode
                return DirectorAdvice(
                    message: abs(diff) < 10 ? "TARGET LOCKED" : "ALIGNING...",
                    icon: "scope",
                    isUrgent: false,
                    lightingScore: 100,
                    turnAngle: diff
                )
            } else {
                // "Video Game" Mode: Arrow sticks to the side
                // We clamp the angle so the arrow points "Off screen" to the left or right
                return DirectorAdvice(
                    message: "Target is Behind (\(distString))",
                    icon: "arrow.turn.up.left", // Icon doesn't matter much here, we rely on rotation
                    isUrgent: true,
                    lightingScore: 50,
                    turnAngle: diff > 0 ? 90 : -90 // Lock arrow to hard Left or Right
                )
            }
        }
    
    // EVALUATE LIGHTING (Keep this for later use)
    static func evaluate(sunPosition: SunPosition, deviceHeading: CLHeading?, isPersonDetected: Bool) -> DirectorAdvice {
        // Placeholder for when you switch back to Sun Mode
        return DirectorAdvice(message: "Tracking Sun...", icon: "sun.max", isUrgent: false, lightingScore: 0, turnAngle: 0)
    }
}
