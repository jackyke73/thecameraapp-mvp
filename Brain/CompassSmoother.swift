import Foundation

class CompassSmoother {
    private var lastHeading: Double = 0
    private let filterFactor: Double = 0.15 // Lower = Smoother (but slower), Higher = More responsive (but jittery)
    
    func smooth(_ newHeading: Double) -> Double {
        // 1. Handle the "Wrap Around" problem (359° -> 1°)
        // If we don't do this, the arrow will spin 360 degrees the wrong way when you cross North.
        let diff = newHeading - lastHeading
        if diff > 180 { lastHeading += 360 }
        else if diff < -180 { lastHeading -= 360 }
        
        // 2. Apply Low-Pass Filter (The "Shock Absorber")
        // New = Old + (Difference * Factor)
        lastHeading = lastHeading + (newHeading - lastHeading) * filterFactor
        
        // 3. Normalize back to 0-360 range
        return (lastHeading + 360).truncatingRemainder(dividingBy: 360)
    }
}
