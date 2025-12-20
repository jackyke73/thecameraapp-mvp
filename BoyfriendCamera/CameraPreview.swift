#if canImport(UIKit)
import Foundation
import SwiftUI
import AVFoundation
import UIKit

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var cameraManager: CameraManager

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.session = cameraManager.session
        
        // 1. Tap to Focus
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tapGesture)
        
        // 2. Hold to Lock AE/AF
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        view.addGestureRecognizer(longPress)
        
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    // The Bridge between UIKit gestures and SwiftUI Manager
    class Coordinator: NSObject {
        var parent: CameraPreview
        
        init(_ parent: CameraPreview) {
            self.parent = parent
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? CameraPreviewView else { return }
            let location = gesture.location(in: view)
            
            // Convert screen touch to Camera Focus Point (0.0 to 1.0)
            let capturePoint = view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: location)
            
            // Visual Haptic
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            
            // Call Manager
            parent.cameraManager.setFocus(point: capturePoint)
            
            // Optional: You could draw a box here using a UIView overlay, but keeping it simple for now.
        }
        
        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                parent.cameraManager.lockFocusAndExposure()
            }
        }
    }
}

// Wrapper to expose the PreviewLayer for coordinate conversion
class CameraPreviewView: UIView {
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
    
    var session: AVCaptureSession? {
        get { return videoPreviewLayer.session }
        set { videoPreviewLayer.session = newValue }
    }
    
    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        videoPreviewLayer.frame = bounds
        videoPreviewLayer.videoGravity = .resizeAspectFill
    }
}

#else
import SwiftUI
struct CameraPreview: View {
    @ObservedObject var cameraManager: CameraManager
    var body: some View { Text("Camera preview unavailable") }
}
#endif
