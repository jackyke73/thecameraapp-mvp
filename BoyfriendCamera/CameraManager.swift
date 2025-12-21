import AVFoundation
import SwiftUI
import Combine
import Vision
import Photos
import UIKit

class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {

    @Published var permissionGranted = false
    @Published var isPersonDetected = false
    @Published var capturedImage: UIImage?
    
    // Capabilities
    @Published var isWBSupported: Bool = false
    @Published var isFocusSupported: Bool = false
    @Published var isTorchSupported: Bool = false
    
    // Zoom
    @Published var minZoomFactor: CGFloat = 0.5
    @Published var maxZoomFactor: CGFloat = 15.0
    @Published var currentZoomFactor: CGFloat = 1.0
    @Published var zoomButtons: [CGFloat] = [0.5, 1.0, 2.0, 4.0]
    
    // Timer
    @Published var isTimerRunning = false
    @Published var timerCount = 0
    
    // Camera Position (Back by default)
    @Published var currentPosition: AVCaptureDevice.Position = .back

    private var zoomScaler: CGFloat = 2.0

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cameraQueue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    
    private var activeDevice: AVCaptureDevice?
    private var deviceInput: AVCaptureDeviceInput?
    private let bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    
    private var pendingLocation: CLLocation?
    private var pendingAspectRatio: CGFloat = 4.0/3.0
    
    let captureDidFinish = PassthroughSubject<Void, Never>()

    override init() {
        super.init()
        checkPermissions()
    }
    
    // MARK: - SWITCH CAMERA
    func switchCamera() {
        // Toggle Position
        currentPosition = (currentPosition == .back) ? .front : .back
        
        // Restart Setup
        sessionQueue.async {
            self.session.stopRunning()
            // Remove Inputs
            if let input = self.deviceInput {
                self.session.removeInput(input)
                self.deviceInput = nil
            }
            // Re-setup
            self.setupCamera()
        }
    }

    // MARK: - SETTINGS (Exposure, WB, Focus, Torch)
    // (Same as before, just kept compact)
    func setExposure(ev: Float) {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            do { try device.lockForConfiguration(); device.setExposureTargetBias(ev, completionHandler: nil); device.unlockForConfiguration() } catch {}
        }
    }
    func setWhiteBalance(kelvin: Float) {
        sessionQueue.async {
            guard let device = self.activeDevice, device.isWhiteBalanceModeSupported(.locked) else { return }
            do {
                try device.lockForConfiguration()
                let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
                var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
                let maxG = device.maxWhiteBalanceGain
                gains.redGain = max(1.0, min(gains.redGain, maxG))
                gains.greenGain = max(1.0, min(gains.greenGain, maxG))
                gains.blueGain = max(1.0, min(gains.blueGain, maxG))
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }
    func setLensPosition(_ position: Float) {
        sessionQueue.async {
            guard let device = self.activeDevice, device.isFocusModeSupported(.locked) else { return }
            do { try device.lockForConfiguration(); device.setFocusModeLocked(lensPosition: position, completionHandler: nil); device.unlockForConfiguration() } catch {}
        }
    }
    func setTorchLevel(_ level: Float) {
        sessionQueue.async {
            guard let device = self.activeDevice, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if level <= 0.01 { device.torchMode = .off } else { try device.setTorchModeOn(level: max(0.01, min(1.0, level))) }
                device.unlockForConfiguration()
            } catch {}
        }
    }
    func resetSettings() {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(0, completionHandler: nil)
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.hasTorch { device.torchMode = .off }
                device.unlockForConfiguration()
            } catch {}
        }
    }
    
    // MARK: - ZOOM
    func setZoomInstant(_ uiFactor: CGFloat) {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            let nativeFactor = uiFactor * self.zoomScaler
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minAvailableVideoZoomFactor, min(nativeFactor, device.maxAvailableVideoZoomFactor))
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.currentZoomFactor = uiFactor }
            } catch {}
        }
    }
    func setZoomSmooth(_ uiFactor: CGFloat) {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            let nativeFactor = uiFactor * self.zoomScaler
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minAvailableVideoZoomFactor, min(nativeFactor, device.maxAvailableVideoZoomFactor))
                device.ramp(toVideoZoomFactor: clamped, withRate: 5.0)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.currentZoomFactor = uiFactor }
            } catch {}
        }
    }

    // MARK: - CAPTURE
    func capturePhoto(location: CLLocation?, aspectRatioValue: CGFloat, useTimer: Bool) {
        if useTimer {
            self.timerCount = 3; self.isTimerRunning = true
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                self.timerCount -= 1
                if self.timerCount <= 0 {
                    timer.invalidate(); self.isTimerRunning = false
                    self.performCapture(location: location, ratio: aspectRatioValue)
                }
            }
        } else {
            performCapture(location: location, ratio: aspectRatioValue)
        }
    }
    
    private func performCapture(location: CLLocation?, ratio: CGFloat) {
        AudioServicesPlaySystemSound(1108)
        pendingLocation = location
        pendingAspectRatio = ratio
        sessionQueue.async {
            if let connection = self.photoOutput.connection(with: .video) {
                // Keep orientation portrait for consistency
                connection.videoOrientation = .portrait
                // FIX: If front camera, mirror logic is usually handled by the system or post-processing,
                // but standard AVCapture doesn't auto-mirror photo output by default.
                // We will leave it raw (reality) and rely on preview being mirrored.
            }
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let originalImage = UIImage(data: data) else { return }
        
        // Fix Orientation
        var fixedImage = fixOrientation(img: originalImage)
        
        // MIRROR IF FRONT CAMERA (Selfie Mode)
        if self.currentPosition == .front {
            if let cgImage = fixedImage.cgImage {
                // Flipping horizontally
                fixedImage = UIImage(cgImage: cgImage, scale: fixedImage.scale, orientation: .leftMirrored)
                fixedImage = fixOrientation(img: fixedImage) // Bake it in
            }
        }
        
        let croppedImage = cropToRatio(fixedImage, ratio: pendingAspectRatio)
        DispatchQueue.main.async { self.capturedImage = croppedImage }
        if let jpegData = croppedImage.jpegData(compressionQuality: 1.0) {
            saveToCustomAlbum(imageData: jpegData, location: pendingLocation)
        }
        DispatchQueue.main.async { self.captureDidFinish.send(()) }
    }
    
    private func cropToRatio(_ image: UIImage, ratio: CGFloat) -> UIImage {
        let w = image.size.width; let h = image.size.height
        var newW = w; var newH = h
        let currentRatio = h / w
        if currentRatio > ratio { newH = w * ratio } else { newW = h / ratio }
        let x = (w - newW) / 2.0; let y = (h - newH) / 2.0
        if let cg = image.cgImage?.cropping(to: CGRect(x: x, y: y, width: newW, height: newH)) {
            return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
        }
        return image
    }
    
    private func fixOrientation(img: UIImage) -> UIImage {
        if img.imageOrientation == .up { return img }
        UIGraphicsBeginImageContextWithOptions(img.size, false, img.scale)
        img.draw(in: CGRect(origin: .zero, size: img.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext() ?? img
        UIGraphicsEndImageContext()
        return normalized
    }

    private func saveToCustomAlbum(imageData: Data, location: CLLocation?) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            let name = "Boyfriend Camera"
            let fetchOptions = PHFetchOptions(); fetchOptions.predicate = NSPredicate(format: "title = %@", name)
            let collection = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
            if let album = collection.firstObject { self.saveAsset(data: imageData, location: location, to: album) }
            else {
                PHPhotoLibrary.shared().performChanges({
                    let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                    _ = req.placeholderForCreatedAssetCollection
                }, completionHandler: { success, _ in
                    if success {
                        let opts = PHFetchOptions(); opts.predicate = NSPredicate(format: "title = %@", name)
                        if let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: opts).firstObject {
                            self.saveAsset(data: imageData, location: location, to: album)
                        }
                    }
                })
            }
        }
    }
    
    private func saveAsset(data: Data, location: CLLocation?, to album: PHAssetCollection) {
        PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: data, options: nil)
            req.location = location
            guard let albumReq = PHAssetCollectionChangeRequest(for: album) else { return }
            albumReq.addAssets([req.placeholderForCreatedAsset!] as NSArray)
        }
    }

    // MARK: - SETUP (Handles Front/Back)
    private func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        
        var device: AVCaptureDevice?
        
        if currentPosition == .back {
            // Find best Back Camera
            let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
            device = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices.first
            self.zoomScaler = 2.0 // Assume Pro lens logic
            
            // Fallback for single lens
            if device?.deviceType == .builtInWideAngleCamera { self.zoomScaler = 1.0 }
        } else {
            // Find Front Camera
            device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            // Or TrueDepth
            if device == nil {
                device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
            }
            self.zoomScaler = 1.0
        }
        
        guard let activeDevice = device else {
            session.commitConfiguration()
            return
        }
        
        self.activeDevice = activeDevice
        
        do {
            let input = try AVCaptureDeviceInput(device: activeDevice)
            if session.canAddInput(input) { session.addInput(input) }
            self.deviceInput = input
        } catch { print("Input Error: \(error)") }
        
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        
        // MIRROR PREVIEW IF FRONT
        if let conn = videoOutput.connection(with: .video) {
            conn.videoOrientation = .portrait
            if currentPosition == .front {
                conn.isVideoMirrored = true
            } else {
                conn.isVideoMirrored = false
            }
        }
        
        session.commitConfiguration()
        session.startRunning()
        
        // Update UI State on Main Thread
        DispatchQueue.main.async {
            if self.currentPosition == .back {
                self.minZoomFactor = 0.5
                self.maxZoomFactor = activeDevice.maxAvailableVideoZoomFactor / self.zoomScaler
                self.zoomButtons = [0.5, 1.0, 2.0, 4.0]
            } else {
                // Front Camera Defaults
                self.minZoomFactor = 1.0
                self.maxZoomFactor = activeDevice.maxAvailableVideoZoomFactor // Usually small digital zoom only
                self.zoomButtons = [1.0] // Only 1x for selfie
            }
            
            self.isWBSupported = activeDevice.isWhiteBalanceModeSupported(.locked)
            self.isFocusSupported = activeDevice.isFocusModeSupported(.locked)
            self.isTorchSupported = activeDevice.hasTorch
            
            self.setZoomInstant(1.0)
        }
    }
    
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: sessionQueue.async { self.setupCamera() }
        default: AVCaptureDevice.requestAccess(for: .video) { if $0 { self.sessionQueue.async { self.setupCamera() } } }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([bodyPoseRequest])
        DispatchQueue.main.async { self.isPersonDetected = (self.bodyPoseRequest.results?.first != nil) }
    }
    func setFocus(point: CGPoint) { sessionQueue.async { guard let device = self.activeDevice else { return }; do { try device.lockForConfiguration(); if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point; device.focusMode = .autoFocus }; if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point; device.exposureMode = .autoExpose }; device.unlockForConfiguration() } catch {} } }
}
