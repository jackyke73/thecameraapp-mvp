import AVFoundation
import SwiftUI
import Combine
import Vision
import Photos
import AudioToolbox

class CameraManager: NSObject, ObservableObject,
                     AVCaptureVideoDataOutputSampleBufferDelegate,
                     AVCapturePhotoCaptureDelegate {

    @Published var permissionGranted = false
    @Published var isPersonDetected = false
    @Published var capturedImage: UIImage?
    @Published var minZoomFactor: CGFloat = 1.0
    @Published var maxZoomFactor: CGFloat = 5.0 // Updated default max

    // Lens switchover zoom factors (for virtual/multi-camera devices)
    private var lensSwitchOverFactors: [CGFloat] = []

    // Common presets we try to expose if the device supports them
    var suggestedZoomPresets: [CGFloat] {
        var candidates: [CGFloat] = [0.5, 1.0, 2.0, 3.0, 5.0] // Added 5.0 for newer pros
        // Add lens switchovers for better fidelity
        candidates.append(contentsOf: lensSwitchOverFactors)
        // Deduplicate and filter to min/max
        let epsilon: CGFloat = 0.001
        let filtered = Set(candidates).filter { $0 >= minZoomFactor - epsilon && $0 <= maxZoomFactor + epsilon }
        var result = Array(filtered)
        if 1.0 >= minZoomFactor - epsilon && 1.0 <= maxZoomFactor + epsilon && !result.contains(1.0) {
            result.append(1.0)
        }
        result.sort()
        return result
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cameraQueue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    
    // NEW: Track active device to control focus/zoom
    private var activeDevice: AVCaptureDevice?
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

    // MARK: - Camera Actions

    // 1. ZOOM FUNCTION
    func zoom(factor: CGFloat) {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                let lower = max(device.minAvailableVideoZoomFactor, self.minZoomFactor)
                let upper = min(device.maxAvailableVideoZoomFactor, self.maxZoomFactor)
                var target = factor
                // Snap to 1.0 exactly if close
                if abs(factor - 1.0) < 0.001 { target = 1.0 }
                
                let clampedFactor = max(lower, min(target, upper))
                device.ramp(toVideoZoomFactor: clampedFactor, withRate: 5.0) // Faster rate for pinch
                device.unlockForConfiguration()
            } catch {
                print("Zoom error: \(error.localizedDescription)")
            }
        }
    }
    
    // 2. TAP TO FOCUS
    func setFocus(point: CGPoint) {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                
                if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                
                device.unlockForConfiguration()
            } catch {
                print("Focus error: \(error)")
            }
        }
    }
    
    // 3. HOLD TO LOCK (AE/AF LOCK)
    func lockFocusAndExposure() {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                device.unlockForConfiguration()
            } catch {
                print("Lock error: \(error)")
            }
        }
    }

    // 4. SWITCH CAMERA FUNCTION
    func switchCamera() {
        sessionQueue.async {
            let newPosition: AVCaptureDevice.Position = (self.currentCameraPosition == .back) ? .front : .back
            self.setupCamera(position: newPosition)
        }
    }

    // 5. CAPTURE PHOTO
    func capturePhoto(location: CLLocation?) {
        AudioServicesPlaySystemSound(1108)
        
        pendingLocation = location

        sessionQueue.async {
            // Ensure connection is active
            if let connection = self.photoOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
                // Mirror selfie if needed
                if self.currentCameraPosition == .front && connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }
            
            let settings = AVCapturePhotoSettings()
            if self.photoOutput.isHighResolutionCaptureEnabled {
                settings.isHighResolutionPhotoEnabled = true
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Setup Logic

    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.setupCamera(position: .back) }
            DispatchQueue.main.async { self.permissionGranted = true }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.setupCamera(position: .back) }
                    DispatchQueue.main.async { self.permissionGranted = true }
                }
            }
        default: break
        }
    }

    private func setupCamera(position: AVCaptureDevice.Position) {
        self.session.beginConfiguration()
        self.currentCameraPosition = position
        
        // 1. Remove existing input
        if let currentInput = deviceInput {
            session.removeInput(currentInput)
        }
        
        // 2. INTELLIGENT DEVICE DISCOVERY
        // We prioritize "Triple" or "Dual Wide" to get the 0.5x lens support
        var device: AVCaptureDevice?
        
        if position == .back {
            if let triple = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
                device = triple
            } else if let dualWide = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) {
                device = dualWide
            } else if let dual = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
                device = dual
            } else {
                device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            }
        } else {
            // Front Camera
            device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        
        guard let validDevice = device else {
            print("No camera found")
            self.session.commitConfiguration()
            return
        }
        
        self.activeDevice = validDevice

        // Capture virtual device switchover zoom factors
        if validDevice.isVirtualDevice {
            self.lensSwitchOverFactors = validDevice.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        } else {
            self.lensSwitchOverFactors = []
        }

        // Update zoom capability bounds for UI
        let minFactor = validDevice.minAvailableVideoZoomFactor
        let maxFactor = validDevice.maxAvailableVideoZoomFactor
        DispatchQueue.main.async {
            self.minZoomFactor = minFactor
            self.maxZoomFactor = maxFactor
        }

        // Schedule initial zoom to 1.0x
        // Note: For UltraWide phones, minFactor might be 0.5. We usually want to start at 1.0.
        let initialZoom: CGFloat = (1.0 >= minFactor && 1.0 <= maxFactor) ? 1.0 : minFactor
        
        self.sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.deviceInput == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.zoom(factor: initialZoom)
                }
            } else {
                self.zoom(factor: initialZoom)
            }
        }

        // 3. Add Input
        do {
            let input = try AVCaptureDeviceInput(device: validDevice)
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.deviceInput = input
            }
        } catch {
            print("Error connecting camera: \(error.localizedDescription)")
            self.session.commitConfiguration()
            return
        }

        // 4. Setup Outputs
        if self.session.outputs.isEmpty {
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
                let videoQueue = DispatchQueue(label: "videoQueue")
                self.videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
            }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.isHighResolutionCaptureEnabled = true
            }
        }
        
        // 5. Fix Orientation
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
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
            if bodyPoseRequest.results?.first != nil {
                DispatchQueue.main.async { if !self.isPersonDetected { self.isPersonDetected = true } }
            } else {
                DispatchQueue.main.async { if self.isPersonDetected { self.isPersonDetected = false } }
            }
        } catch {
            print("Vision error: \(error.localizedDescription)")
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            print("Photo capture error: \(error.localizedDescription)")
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }

        DispatchQueue.main.async { self.capturedImage = image }

        saveToPhotos(imageData: data, location: pendingLocation)
        pendingLocation = nil
        DispatchQueue.main.async { self.captureDidFinish.send(()) }
    }

    private func saveToPhotos(imageData: Data, location: CLLocation?) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: imageData, options: nil)
                request.location = location
            }, completionHandler: { success, error in
                if let error = error {
                    print("Save error: \(error.localizedDescription)")
                }
            })
        }
    }
}
