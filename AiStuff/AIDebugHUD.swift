import SwiftUI

struct AIDebugHUD: View {
    @ObservedObject var cameraManager: CameraManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(cameraManager.isAIFeaturesEnabled ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(cameraManager.isAIFeaturesEnabled ? "AI ON" : "AI OFF")
                    .font(.caption.bold())
            }

            HStack {
                Text("Person:")
                Text(cameraManager.isPersonDetected ? "Yes" : "No")
                    .fontWeight(.bold)
            }
            .font(.caption)

            HStack {
                Text("Count:")
                Text("\(cameraManager.peopleCount)")
                    .fontWeight(.bold)
            }
            .font(.caption)

            if !cameraManager.expressions.isEmpty {
                Text("Expr: " + cameraManager.expressions.joined(separator: ", "))
                    .font(.caption)
            } else {
                Text("Expr: —")
                    .font(.caption)
            }
        }
        .foregroundColor(.white)
        .padding(10)
        // Liquid Glass style (matches your app's ultraThinMaterial look)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 4)
    }
}
