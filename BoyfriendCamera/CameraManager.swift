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
    
    // Capabilities (Dynamic)
    @Published var isWBSupported: Bool = false
    @Published var isFocusSupported: Bool = false
    @Published var isTorchSupported: Bool = false
    
    // State
    @Published var minZoomFactor: CGFloat = 0.5
    @Published var maxZoomFactor: CGFloat = 15.0
    @Published var currentZoomFactor: CGFloat = 1.0
    @Published var zoomButtons: [CGFloat] = [0.5, 1.0, 2.0, 4.0]
    
    // Timer State
    @Published var isTimerRunning = false
    @Published var timerCount = 0

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

    // MARK: - PRO SETTINGS (Hardened)
    
    func setExposure(ev: Float) {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(ev, completionHandler: nil)
                device.unlockForConfiguration()
            } catch { print("Exposure error: \(error)") }
        }
    }
    
    func setWhiteBalance(kelvin: Float) {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            
            // 1. Check support to prevent "Kill"
            if !device.isWhiteBalanceModeSupported(.locked) { return }
            
            do {
                try device.lockForConfiguration()
                
                // 2. Calculate Gains
                let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
                var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
                
                // 3. STRICT SAFETY CLAMP (Prevents Crash)
                let maxG = device.maxWhiteBalanceGain
                // Typically max gain is around 3.0-4.0. We clamp to be safe.
                gains.redGain = max(1.0, min(gains.redGain, maxG))
                gains.greenGain = max(1.0, min(gains.greenGain, maxG))
                gains.blueGain = max(1.0, min(gains.blueGain, maxG))
                
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                device.unlockForConfiguration()
            } catch { print("WB Calc Error: \(error)") }
        }
    }
    
    func setLensPosition(_ position: Float) {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            // Check capability
            if !device.isFocusModeSupported(.locked) { return }
            
            do {
                try device.lockForConfiguration()
                device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
                device.unlockForConfiguration()
            } catch { print("Focus Error: \(error)") }
        }
    }
    
    func setTorchLevel(_ level: Float) {
        sessionQueue.async {
            guard let device = self.activeDevice, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                if level <= 0.01 {
                    device.torchMode = .off
                } else {
                    // Torch level must be between 0.0 and 1.0 (exclusive of 0)
                    try device.setTorchModeOn(level: max(0.01, min(1.0, level)))
                }
                device.unlockForConfiguration()
            } catch { print("Torch Error: \(error)") }
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
            } catch { print("Reset Error: \(error)") }
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
            } catch { print("Zoom Error: \(error)") }
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
            } catch { print("Zoom Error: \(error)") }
        }
    }

    // MARK: - CAPTURE WITH TIMER
    func capturePhoto(location: CLLocation?, aspectRatioValue: CGFloat, useTimer: Bool) {
        if useTimer {
            // Start Timer on Main Thread
            self.timerCount = 3
            self.isTimerRunning = true
            
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                self.timerCount -= 1
                if self.timerCount <= 0 {
                    timer.invalidate()
                    self.isTimerRunning = false
                    // Actually take the photo
                    self.performCapture(location: location, ratio: aspectRatioValue)
                }
            }
        } else {
            // Instant
            performCapture(location: location, ratio: aspectRatioValue)
        }
    }
    
    private func performCapture(location: CLLocation?, ratio: CGFloat) {
        AudioServicesPlaySystemSound(1108)
        pendingLocation = location
        pendingAspectRatio = ratio
        
        sessionQueue.async {
            if let connection = self.photoOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
            }
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let originalImage = UIImage(data: data) else { return }
        let croppedImage = cropToRatio(originalImage, ratio: pendingAspectRatio)
        DispatchQueue.main.async { self.capturedImage = croppedImage }
        if let jpegData = croppedImage.jpegData(compressionQuality: 1.0) {
            saveToCustomAlbum(imageData: jpegData, location: pendingLocation)
        }
        DispatchQueue.main.async { self.captureDidFinish.send(()) }
    }
    
    private func cropToRatio(_ image: UIImage, ratio: CGFloat) -> UIImage {
        let w = image.size.width; let h = image.size.height
        let currentRatio = w / h
        var newW = w; var newH = h
        if currentRatio > ratio { newW = h * ratio } else { newH = w / ratio }
        let x = (w - newW) / 2.0; let y = (h - newH) / 2.0
        guard let cg = image.cgImage?.cropping(to: CGRect(x: x, y: y, width: newW, height: newH)) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
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

    // MARK: - SETUP
    private func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        
        let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera]
        guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .back).devices.first else {
            setupStandardCamera(); return
        }
        self.activeDevice = device
        self.zoomScaler = 2.0
        
        DispatchQueue.main.async {
            self.minZoomFactor = 0.5
            self.maxZoomFactor = device.maxAvailableVideoZoomFactor / self.zoomScaler
            self.zoomButtons = [0.5, 1.0, 2.0, 4.0]
            // Update Capabilities
            self.isWBSupported = device.isWhiteBalanceModeSupported(.locked)
            self.isFocusSupported = device.isFocusModeSupported(.locked)
            self.isTorchSupported = device.hasTorch
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            deviceInput = input
        } catch { print("Input Error: \(error)") }
        
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.connection(with: .video)?.videoOrientation = .portrait
        session.commitConfiguration()
        session.startRunning()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.setZoomInstant(1.0) }
    }
    
    private func setupStandardCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        self.activeDevice = device
        self.zoomScaler = 1.0
        DispatchQueue.main.async {
            self.minZoomFactor = 1.0; self.maxZoomFactor = 5.0; self.zoomButtons = [1.0, 2.0]
            self.isWBSupported = device.isWhiteBalanceModeSupported(.locked)
            self.isFocusSupported = device.isFocusModeSupported(.locked)
            self.isTorchSupported = device.hasTorch
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            deviceInput = input
        } catch { return }
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.connection(with: .video)?.videoOrientation = .portrait
        session.commitConfiguration()
        session.startRunning()
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
    func setFocus(point: CGPoint) {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point; device.focusMode = .autoFocus }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point; device.exposureMode = .autoExpose }
                device.unlockForConfiguration()
            } catch { print("Focus Error: \(error)") }
        }
    }
}
