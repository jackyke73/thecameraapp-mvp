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
    
    // Zoom Limits
    @Published var minZoomFactor: CGFloat = 0.5
    @Published var maxZoomFactor: CGFloat = 15.0
    @Published var currentZoomFactor: CGFloat = 1.0
    
    // Buttons
    @Published var zoomButtons: [CGFloat] = [0.5, 1.0, 2.0, 4.0]

    // Scaler (UI 1.0 = Native 2.0 on Pro phones)
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

    // MARK: - ZOOM LOGIC (Split into Instant vs Smooth)
    
    // 1. INSTANT ZOOM (For Dial & Pinch - Zero Latency)
    func setZoomInstant(_ uiFactor: CGFloat) {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            
            // Convert to Native
            let nativeFactor = uiFactor * self.zoomScaler
            
            do {
                try device.lockForConfiguration()
                // Clamp strictly
                let clamped = max(device.minAvailableVideoZoomFactor, min(nativeFactor, device.maxAvailableVideoZoomFactor))
                
                // DIRECT SET (No Ramping)
                device.videoZoomFactor = clamped
                
                device.unlockForConfiguration()
                
                DispatchQueue.main.async { self.currentZoomFactor = uiFactor }
            } catch {
                print("Zoom error: \(error)")
            }
        }
    }
    
    // 2. SMOOTH ZOOM (For Buttons - Cinematic Transition)
    func setZoomSmooth(_ uiFactor: CGFloat) {
        sessionQueue.async {
            guard let device = self.activeDevice else { return }
            let nativeFactor = uiFactor * self.zoomScaler
            
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minAvailableVideoZoomFactor, min(nativeFactor, device.maxAvailableVideoZoomFactor))
                
                // RAMP (Smooth)
                device.ramp(toVideoZoomFactor: clamped, withRate: 5.0)
                
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.currentZoomFactor = uiFactor }
            } catch {
                print("Zoom error: \(error)")
            }
        }
    }

    // MARK: - CAPTURE
    
    func capturePhoto(location: CLLocation?, aspectRatioValue: CGFloat) {
        AudioServicesPlaySystemSound(1108)
        pendingLocation = location
        pendingAspectRatio = aspectRatioValue
        
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
        let w = image.size.width
        let h = image.size.height
        let currentRatio = w / h
        var newW = w
        var newH = h
        if currentRatio > ratio { newW = h * ratio } else { newH = w / ratio }
        let x = (w - newW) / 2.0
        let y = (h - newH) / 2.0
        guard let cg = image.cgImage?.cropping(to: CGRect(x: x, y: y, width: newW, height: newH)) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    private func saveToCustomAlbum(imageData: Data, location: CLLocation?) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            let name = "Boyfriend Camera"
            let fetchOptions = PHFetchOptions()
            fetchOptions.predicate = NSPredicate(format: "title = %@", name)
            let collection = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
            
            if let album = collection.firstObject {
                self.saveAsset(data: imageData, location: location, to: album)
            } else {
                var placeholder: PHObjectPlaceholder?
                PHPhotoLibrary.shared().performChanges({
                    let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                    placeholder = req.placeholderForCreatedAssetCollection
                }, completionHandler: { success, _ in
                    if success, let id = placeholder?.localIdentifier {
                        if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
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

    // MARK: - HARDWARE SETUP

    private func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        
        let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera]
        guard let device = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .back).devices.first else {
            setupStandardCamera()
            return
        }
        self.activeDevice = device
        self.zoomScaler = 2.0
        
        // Init UI State
        DispatchQueue.main.async {
            self.minZoomFactor = 0.5 // STRICT LIMIT
            self.maxZoomFactor = device.maxAvailableVideoZoomFactor / self.zoomScaler
            self.zoomButtons = [0.5, 1.0, 2.0, 4.0]
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
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.setZoomInstant(1.0)
        }
    }
    
    private func setupStandardCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        self.activeDevice = device
        self.zoomScaler = 1.0
        DispatchQueue.main.async {
            self.minZoomFactor = 1.0
            self.maxZoomFactor = 5.0
            self.zoomButtons = [1.0, 2.0]
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
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch { print("Focus error: \(error)") }
        }
    }
}
