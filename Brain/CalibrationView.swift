import SwiftUI

struct CalibrationView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Animated Icon
                Image(systemName: "gyroscope")
                    .font(.system(size: 80))
                    .foregroundColor(.yellow)
                    .symbolEffect(.variableColor.iterative.reversing) // iOS 17 animation
                
                Text("Compass Needs Calibration")
                    .font(.title2)
                    .bold()
                    .foregroundColor(.white)
                
                Text("Wave your phone in a Figure-8 pattern\nuntil this screen disappears.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal)
                
                // Visual Guide (Figure 8)
                Image(systemName: "infinity")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.top, 10)
            }
        }
    }
}

#Preview {
    CalibrationView()
}
