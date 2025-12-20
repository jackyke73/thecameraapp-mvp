import Foundation

class CompassSmoother {
    private var lastHeading: Double = 0
    
    // CHANGED: Lower factor = Heavier/Smoother (0.05 is very smooth, 0.15 is responsive)
    private let filterFactor: Double = 0.05
    
    // NEW: "Dead Zone". If the phone moves less than this amount, ignore it.
    // This kills the "micro-jitters" completely.
    private let threshold: Double = 0.5

    func smooth(_ newHeading: Double) -> Double {
        // 1. Handle Wrap Around (359 -> 1)
        var diff = newHeading - lastHeading
        if diff > 180 { diff -= 360 }
        else if diff < -180 { diff += 360 }
        
        // 2. DEAD ZONE CHECK (The "Anti-Giggle" Feature)
        // If the movement is tiny, just return the old value. Don't move the UI.
        if abs(diff) < threshold {
            return lastHeading
        }
        
        // 3. Low Pass Filter
        lastHeading = lastHeading + (diff * filterFactor)
        
        return (lastHeading + 360).truncatingRemainder(dividingBy: 360)
    }
}
