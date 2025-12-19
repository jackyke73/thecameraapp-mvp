import Foundation
import CoreLocation // We need this for the coordinate types

struct SunPosition {
    let azimuth: Double   // 0 to 360 degrees
    let elevation: Double // -90 to 90 degrees
    let isGoldenHour: Bool
}

class SunCalculator {
    
    // The Main Function: Input (Time, Location) -> Output (Sun Position)
    static func compute(date: Date, coordinate: CLLocationCoordinate2D) -> SunPosition {
        
        // 1. Convert Date to Julian Days (Standard astronomical time unit)
        let calendar = Calendar(identifier: .gregorian)
        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        
        let decimalHour = Double(calendar.component(.hour, from: date)) +
                          Double(calendar.component(.minute, from: date)) / 60.0 +
                          Double(calendar.component(.second, from: date)) / 3600.0
        
        // 2. Calculate Declination of the Sun (The tilt of the earth)
        // Formula: approx 23.45 * sin(360/365 * (d - 81))
        let declinationRad = toRad(23.45) * sin(toRad(360/365.0 * (dayOfYear - 81)))
        
        // 3. Equation of Time (Correction for earth's elliptical orbit)
        // Output is in minutes
        let B = toRad(360/365.0 * (dayOfYear - 81))
        let eotMinutes = 9.87 * sin(2 * B) - 7.53 * cos(B) - 1.5 * sin(B)
        
        // 4. Solar Time Offset
        // Every degree of longitude is 4 minutes of time difference from UTC
        let timeOffset = 4.0 * coordinate.longitude + eotMinutes
        let solarTime = decimalHour + timeOffset / 60.0
        
        // 5. Solar Hour Angle (H)
        // 0 = Solar Noon, Negative = Morning, Positive = Afternoon
        let hourAngleRad = toRad(15.0 * (solarTime - 12.0))
        
        // 6. Calculate Elevation (Altitude)
        let latRad = toRad(coordinate.latitude)
        
        // Standard Spherical Trigonometry Formula for Altitude
        let elevationRad = asin(sin(latRad) * sin(declinationRad) +
                                cos(latRad) * cos(declinationRad) * cos(hourAngleRad))
        
        // 7. Calculate Azimuth
        let azimuthRad = acos((sin(declinationRad) - sin(latRad) * sin(elevationRad)) /
                              (cos(latRad) * cos(elevationRad)))
        
        var azimuthDeg = toDeg(azimuthRad)
        // Correction: Azimuth math usually assumes South = 0, we want North = 0
        if Double(calendar.component(.hour, from: date)) >= 12 {
            azimuthDeg = 360 - azimuthDeg
        }
        
        let elevationDeg = toDeg(elevationRad)
        
        // 8. Determine "Golden Hour"
        // Golden hour is generally when sun is between -4° and 6° elevation
        let isGolden = elevationDeg < 6.0 && elevationDeg > -4.0
        
        return SunPosition(azimuth: azimuthDeg, elevation: elevationDeg, isGoldenHour: isGolden)
    }
    
    // Helper: Degrees to Radians
    static func toRad(_ degrees: Double) -> Double {
        return degrees * .pi / 180.0
    }
    
    // Helper: Radians to Degrees
    static func toDeg(_ radians: Double) -> Double {
        return radians * 180.0 / .pi
    }
}
