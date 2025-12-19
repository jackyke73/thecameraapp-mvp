import SwiftUI

struct ScopeView: View {
    let advice: DirectorAdvice
    
    var body: some View {
        ZStack {
            
            // 1. THE CROSSHAIR (Static Center)
            ZStack {
                // Horizontal line
                Rectangle()
                    .frame(width: 40, height: 2)
                // Vertical line
                Rectangle()
                    .frame(width: 2, height: 40)
                // Circle
                Circle()
                    .stroke(lineWidth: 2)
                    .frame(width: 60, height: 60)
            }
            .foregroundColor(isLocked ? .green : .white.opacity(0.5))
            .shadow(color: isLocked ? .green : .black, radius: 10)
            
            // 2. THE GUIDANCE ARROW (Dynamic)
            // It rotates around the center to point at the target
            if !isLocked {
                VStack {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.title)
                        .foregroundColor(.yellow)
                        .padding(.bottom, 120) // Push it out from center
                        .shadow(radius: 5)
                }
                .rotationEffect(.degrees(advice.turnAngle)) // ROTATE THE WHOLE ARROW
                .animation(.spring(), value: advice.turnAngle)
            }
            
            // 3. THE TEXT READOUT (Bottom)
            VStack {
                Spacer()
                
                HStack(spacing: 15) {
                    Image(systemName: isLocked ? "checkmark.circle.fill" : "location.fill")
                        .foregroundColor(isLocked ? .green : .yellow)
                        .font(.title2)
                    
                    VStack(alignment: .leading) {
                        Text(advice.message)
                            .font(.headline)
                            .bold()
                            .foregroundColor(.white)
                        
                        if !isLocked {
                            Text(turnText)
                                .font(.caption)
                                .bold()
                                .foregroundColor(.yellow)
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(15)
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .stroke(isLocked ? Color.green : Color.yellow, lineWidth: 2)
                )
                .padding(.bottom, 60)
            }
        }
    }
    
    // Helpers
    var isLocked: Bool {
        return abs(advice.turnAngle) < 10 && advice.turnAngle != 0 // 0 check to ensure valid data
    }
    
    var turnText: String {
        if advice.turnAngle > 0 { return "Turn RIGHT ->" }
        return "<- Turn LEFT"
    }
}

// Preview to see what it looks like without running
#Preview {
    ZStack {
        Color.black
        ScopeView(advice: DirectorAdvice(message: "Campanile (400m)", icon: "scope", isUrgent: true, lightingScore: 50, turnAngle: 45))
    }
}
