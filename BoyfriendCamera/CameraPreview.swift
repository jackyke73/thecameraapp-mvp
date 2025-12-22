//
//  CameraPreview.swift
//  BoyfriendCamera
//

import SwiftUI
import AVFoundation
import UIKit

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var cameraManager: CameraManager

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.session = cameraManager.session

        // Tap Gesture
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        // Initial connection sync (orientation + mirroring)
        if let conn = view.videoPreviewLayer.connection, conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        if let conn = view.videoPreviewLayer.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (cameraManager.currentPosition == .front)
        }

        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        // Keep session attached
        if uiView.session !== cameraManager.session {
            uiView.session = cameraManager.session
        }

        // Keep orientation + mirroring in sync with camera position
        if let conn = uiView.videoPreviewLayer.connection {
            if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = (cameraManager.currentPosition == .front)
            }
        }

        // Ensure the layer stays sized correctly
        uiView.videoPreviewLayer.frame = uiView.bounds
        uiView.videoPreviewLayer.videoGravity = .resizeAspectFill
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: CameraPreview
        init(_ parent: CameraPreview) { self.parent = parent }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? CameraPreviewView else { return }
            let point = gesture.location(in: view)

            // 1) Visual feedback
            view.showFocusBox(at: point)

            // 2) Convert + focus (USE PREVIEW LAYER CONVERSION)
            // This keeps tap-to-focus correct even with mirroring / aspect fill.
            parent.cameraManager.setFocus(layerPoint: point, previewLayer: view.videoPreviewLayer)

            // 3) Haptic
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

final class CameraPreviewView: UIView {

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }

    var session: AVCaptureSession? {
        get { videoPreviewLayer.session }
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

    // Yellow focus box animation
    func showFocusBox(at point: CGPoint) {
        let box = UIView(frame: CGRect(x: 0, y: 0, width: 70, height: 70))
        box.center = point
        box.layer.borderWidth = 1.5
        box.layer.borderColor = UIColor.systemYellow.cgColor
        box.backgroundColor = UIColor.clear
        box.alpha = 0

        addSubview(box)

        // Animate: Scale down + Fade In -> Fade Out
        box.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
        box.alpha = 1.0

        UIView.animate(withDuration: 0.25, animations: {
            box.transform = .identity
        }) { _ in
            UIView.animate(withDuration: 0.2, delay: 0.5, options: [], animations: {
                box.alpha = 0
            }) { _ in
                box.removeFromSuperview()
            }
        }
    }
}
