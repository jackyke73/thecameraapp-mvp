import AVFoundation
import SwiftUI
import Combine
import Vision
import Photos
import AudioToolbox // Needed for the shutter sound

class CameraManager: NSObject, ObservableObject,
                     AVCaptureVideoDataOutputSampleBufferDelegate,
                     AVCapturePhotoCaptureDelegate {

    @Published var permissionGranted = false
    @Published var isPersonDetected = false
    @Published var capturedImage: UIImage?
    @Published var minZoomFactor: CGFloat = 1.0
    @Published var maxZoomFactor: CGFloat = 1.0

    // Lens switchover zoom factors (for virtual/multi-camera devices)
    private var lensSwitchOverFactors: [CGFloat] = []

    // Common presets we try to expose if the device supports them
    var suggestedZoomPresets: [CGFloat] {
        // Base candidates: common optical stops
        var candidates: [CGFloat] = [0.5, 1.0, 2.0, 3.0]
        // Add lens switchovers for better fidelity
        candidates.append(contentsOf: lensSwitchOverFactors)
        // Deduplicate and filter to min/max
        let epsilon: CGFloat = 0.001
        let filtered = Set(candidates).filter { $0 >= minZoomFactor - epsilon && $0 <= maxZoomFactor + epsilon }
        // Ensure 1.0 is present if supported
        var result = Array(filtered)
        if 1.0 >= minZoomFactor - epsilon && 1.0 <= maxZoomFactor + epsilon && !result.contains(1.0) {
            result.append(1.0)
        }
        // Sort ascending
        result.sort()
        return result
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cameraQueue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    
    // NEW: Track which camera is active
    private var currentCameraPosition: AVCaptureDevice.Position = .back
    private var deviceInput: AVCaptureDeviceInput?

    private let bodyPoseRequest = VNDetectHumanBodyPoseRequest()

    // Store the location at the moment the shutter is pressed
    private var pendingLocation: CLLocation?

    // Publisher to notify UI when capture+save finishes
    let captureDidFinish = PassthroughSubject<Void, Never>()

    override init() {
        super.init()
        checkPermissions()
    }

    // MARK: - Camera Actions (Zoom, Switch, Capture)

    // 1. ZOOM FUNCTION
    func zoom(factor: CGFloat) {
        sessionQueue.async {
            guard let device = self.deviceInput?.device else { return }
            do {
                try device.lockForConfiguration()
                // Clamp zoom to safe limits (e.g., 1x to 5x)
                let lower = max(device.minAvailableVideoZoomFactor, self.minZoomFactor)
                let upper = min(device.maxAvailableVideoZoomFactor, self.maxZoomFactor)
                var target = factor
                if abs(factor - 1.0) < 0.001 { target = 1.0 }
                let clampedFactor = max(lower, min(target, upper))
                device.ramp(toVideoZoomFactor: clampedFactor, withRate: 2.0)
                device.unlockForConfiguration()
            } catch {
                print("Zoom error: \(error.localizedDescription)")
            }
        }
    }

    // 2. SWITCH CAMERA FUNCTION
    func switchCamera() {
        sessionQueue.async {
            // Toggle position
            let newPosition: AVCaptureDevice.Position = (self.currentCameraPosition == .back) ? .front : .back
            self.setupCamera(position: newPosition)
        }
    }

    // 3. CAPTURE PHOTO (With Sound & Location)
    func capturePhoto(location: CLLocation?) {
        // Play Shutter Sound immediately on main thread for responsiveness
        AudioServicesPlaySystemSound(1108)
        
        pendingLocation = location

        sessionQueue.async {
            // Ensure connection is active
            if let connection = self.photoOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
            }
            
            let settings = AVCapturePhotoSettings()
            // Flash settings if needed
            // settings.flashMode = .auto
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Setup Logic

    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // Default to back camera
            sessionQueue.async { self.setupCamera(position: .back) }
            DispatchQueue.main.async { self.permissionGranted = true }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.setupCamera(position: .back) }
                    DispatchQueue.main.async { self.permissionGranted = true }
                }
            }
        case .denied, .restricted:
            print("User denied camera permission")
        @unknown default:
            break
        }
    }

    // Refactored to accept position (Front/Back)
    private func setupCamera(position: AVCaptureDevice.Position) {
        self.session.beginConfiguration()
        self.currentCameraPosition = position
        
        // 1. Remove existing input
        if let currentInput = deviceInput {
            session.removeInput(currentInput)
        }
        
        // 2. Find correct device
        // Front: BuiltInWideAngle
        // Back: Try Triple/Dual/Wide in that order
        let deviceTypes: [AVCaptureDevice.DeviceType] = position == .front ?
            [.builtInWideAngleCamera] :
            [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
        
        guard let device = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position
        ).devices.first else {
            print("No camera found for position: \(position)")
            self.session.commitConfiguration()
            return
        }

        // Capture virtual device switchover zoom factors if available
        if device.isVirtualDevice {
            self.lensSwitchOverFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        } else {
            self.lensSwitchOverFactors = []
        }

        // Update zoom capability bounds for UI
        let minFactor = device.minAvailableVideoZoomFactor
        let maxFactor = device.maxAvailableVideoZoomFactor
        DispatchQueue.main.async {
            self.minZoomFactor = minFactor
            self.maxZoomFactor = maxFactor
        }

        // Schedule initial zoom to 1.0x or nearest preset to keep UI and camera aligned
        let initialZoom: CGFloat
        if 1.0 >= minFactor && 1.0 <= maxFactor {
            initialZoom = 1.0
        } else {
            let presets = self.suggestedZoomPresets
            initialZoom = presets.min(by: { abs($0 - 1.0) < abs($1 - 1.0) }) ?? minFactor
        }
        // Apply initial zoom on the session queue after configuration commits
        self.sessionQueue.async { [weak self] in
            guard let self = self else { return }
            // Ensure device input exists before applying zoom
            if self.deviceInput == nil {
                // Delay slightly to allow input to be set and session to start
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.zoom(factor: initialZoom)
                }
            } else {
                self.zoom(factor: initialZoom)
            }
        }

        // 3. Add Input
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.deviceInput = input
            }
        } catch {
            print("Error connecting camera: \(error.localizedDescription)")
            self.session.commitConfiguration()
            return
        }

        // 4. Setup Outputs (Only if not already added)
        if self.session.outputs.isEmpty {
            // Video Output (Vision)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
                let videoQueue = DispatchQueue(label: "videoQueue")
                self.videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
            }
            
            // Photo Output
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.isHighResolutionCaptureEnabled = true
            }
        }
        
        // 5. Fix Orientation for Vision & Preview
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            // Mirror front camera so it looks like a mirror
            if position == .front && connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            } else {
                connection.isVideoMirrored = false
            }
        }

        self.session.commitConfiguration()
        
        if !self.session.isRunning {
            self.session.startRunning()
        }
    }

    // MARK: - Delegates

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])

        do {
            try handler.perform([bodyPoseRequest])
            // Check results
            if bodyPoseRequest.results?.first != nil {
                DispatchQueue.main.async { if !self.isPersonDetected { self.isPersonDetected = true } }
            } else {
                DispatchQueue.main.async { if self.isPersonDetected { self.isPersonDetected = false } }
            }
        } catch {
            print("Vision error: \(error.localizedDescription)")
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {

        if let error = error {
            print("Photo capture error: \(error.localizedDescription)")
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }

        DispatchQueue.main.async {
            self.capturedImage = image
        }

        saveToPhotos(imageData: data, location: pendingLocation)
        pendingLocation = nil
        DispatchQueue.main.async {
            self.captureDidFinish.send(())
        }
    }

    private func saveToPhotos(imageData: Data, location: CLLocation?) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                print("Photos permission not granted")
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: imageData, options: nil)
                request.location = location  // Attach GPS
            }, completionHandler: { success, error in
                if let error = error {
                    print("Save to Photos error: \(error.localizedDescription)")
                } else {
                    print("Saved to Photos: \(success)")
                }
            })
        }
    }
}

