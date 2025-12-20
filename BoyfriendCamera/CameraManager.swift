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
    
    // Zoom State
    @Published var minZoomFactor: CGFloat = 1.0
    @Published var maxZoomFactor: CGFloat = 15.0
    @Published var currentZoomFactor: CGFloat = 1.0
    
    enum BackLens {
        case ultraWide
        case wide
        case tele
    }
    private var preferredLens: BackLens = .wide
    
    // Smooth zoom control
    private let zoomRampRate: Float = 8.0 // higher = faster
    private let handoffDownThreshold: CGFloat = 0.85 // when going down, start handoff near 0.85
    private let handoffUpThreshold: CGFloat = 0.65   // when going up from 0.5, finish handoff after 0.65
    private var isSwitchingLens = false

    // Telephoto boundaries (UI factors) derived from hardware switch-over; filled in setup
    private var telephotoThresholds: [CGFloat] = [] // e.g., [3.0, 5.0]
    private let teleHandoffPadding: CGFloat = 0.2    // hysteresis around thresholds

    // LENS SCALING
    // Native 1.0 is often the UltraWide (0.5x). This scaler fixes that.
    private var zoomScaler: CGFloat = 1.0

    // NEW: The list of buttons to show in UI (e.g. .5, 1, 3, 5)
    @Published var zoomButtons: [CGFloat] = [1.0]

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cameraQueue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    
    private var activeDevice: AVCaptureDevice?
    private var deviceInput: AVCaptureDeviceInput?
    private let bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    
    // Capture State
    private var pendingLocation: CLLocation?
    private var pendingAspectRatio: CGFloat = 4.0/3.0 // Default to full sensor
    
    let captureDidFinish = PassthroughSubject<Void, Never>()

    override init() {
        super.init()
        checkPermissions()
    }

    // MARK: - ZOOM LOGIC (Dynamic)
    
    func setZoom(_ uiFactor: CGFloat) {
        sessionQueue.async {
            // If we are in the middle of a lens switch, ignore new requests briefly
            if self.isSwitchingLens { return }
            guard let device = self.activeDevice else { return }

            var targetUI = max(0.5, uiFactor)

            // Telephoto handoff logic
            if let tele = self.telephotoTarget(for: targetUI) {
                if tele.shouldSwitch {
                    self.isSwitchingLens = true
                    switch tele.targetLens {
                    case .tele:
                        self.switchToTelephotoIfAvailable(targetUIZoom: tele.snapUI)
                    case .wide:
                        self.switchToWideIfAvailable(targetUIZoom: tele.snapUI)
                    default: break
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                        self.sessionQueue.async { self.isSwitchingLens = false }
                    }
                    return
                }
            }

            // Smooth lens handoff with hysteresis around ~0.75x
            switch self.preferredLens {
            case .wide:
                // If user drags below handoffDownThreshold, first ramp wide to ~0.9 native, then switch
                if targetUI <= self.handoffDownThreshold {
                    self.isSwitchingLens = true
                    // 1) Ramp current lens close to its minimum for a smoother visual before switch
                    do {
                        try device.lockForConfiguration()
                        let preSwitchNative = max(device.minAvailableVideoZoomFactor, min(0.95 * self.zoomScaler, device.maxAvailableVideoZoomFactor))
                        device.ramp(toVideoZoomFactor: preSwitchNative, withRate: self.zoomRampRate)
                        device.unlockForConfiguration()
                    } catch {
                        print("Pre-switch ramp error: \(error)")
                    }
                    // 2) Switch to ultra-wide and ramp to 0.5 smoothly
                    self.switchToUltraWideIfAvailable()
                    // Small delay to allow input reconfiguration, then set 0.5
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                        self.sessionQueue.async {
                            self.isSwitchingLens = false
                            self.setZoom(0.5)
                        }
                    }
                    return
                }
            case .ultraWide:
                // If user drags above handoffUpThreshold, switch back to wide at ~1.0 smoothly
                if targetUI >= self.handoffUpThreshold {
                    self.isSwitchingLens = true
                    self.switchToWideIfAvailable(targetUIZoom: max(1.0, targetUI))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                        self.sessionQueue.async { self.isSwitchingLens = false }
                    }
                    return
                }
            default:
                break
            }

            // Continuous ramp on the current active device
            let nativeFactor = targetUI * self.zoomScaler
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minAvailableVideoZoomFactor, min(nativeFactor, device.maxAvailableVideoZoomFactor))
                device.ramp(toVideoZoomFactor: clamped, withRate: self.zoomRampRate)
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.currentZoomFactor = targetUI }
            } catch {
                print("Zoom error: \(error)")
            }
        }
    }

    // Decide if we should switch to telephoto for a target UI zoom
    private func telephotoTarget(for ui: CGFloat) -> (shouldSwitch: Bool, targetLens: BackLens, snapUI: CGFloat)? {
        guard !telephotoThresholds.isEmpty else { return nil }
        // Sort ascending thresholds like [3.0, 5.0]
        let thresholds = telephotoThresholds.sorted()
        if preferredLens == .tele {
            // If we are tele and user drags below the lowest threshold - padding, switch back to wide
            if ui < (thresholds.first! - teleHandoffPadding) { return (true, .wide, max(1.0, ui)) }
            return (false, .tele, ui)
        } else if preferredLens == .wide || preferredLens == .ultraWide {
            // If user goes above any threshold + padding, switch to tele and snap near that threshold
            for t in thresholds.reversed() {
                if ui > (t + teleHandoffPadding) { return (true, .tele, t) }
            }
            return (false, preferredLens, ui)
        }
        return nil
    }

    // MARK: - CAPTURE LOGIC (With Cropping)
    
    // Updated to accept Aspect Ratio
    func capturePhoto(location: CLLocation?, aspectRatioValue: CGFloat) {
        AudioServicesPlaySystemSound(1108)
        
        pendingLocation = location
        pendingAspectRatio = aspectRatioValue
        
        sessionQueue.async {
            // Ensure we are using the full sensor
            if let connection = self.photoOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
            }
            
            let settings = AVCapturePhotoSettings()
            settings.isHighResolutionPhotoEnabled = true
            // Max quality
            if let availableType = settings.availablePreviewPhotoPixelFormatTypes.first {
                settings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: availableType]
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(),
              let originalImage = UIImage(data: data) else { return }
        
        // 1. CROP THE IMAGE
        let croppedImage = cropToRatio(originalImage, ratio: pendingAspectRatio)
        
        DispatchQueue.main.async { self.capturedImage = croppedImage }
        
        // 2. SAVE (The cropped version)
        if let jpegData = croppedImage.jpegData(compressionQuality: 1.0) {
            saveToCustomAlbum(imageData: jpegData, location: pendingLocation)
        }
        
        DispatchQueue.main.async { self.captureDidFinish.send(()) }
    }
    
    // Helper: Physical Crop
    private func cropToRatio(_ image: UIImage, ratio: CGFloat) -> UIImage {
        // Calculate crop rect
        let originalWidth = image.size.width
        let originalHeight = image.size.height
        let currentRatio = originalWidth / originalHeight
        
        var newWidth = originalWidth
        var newHeight = originalHeight
        
        if currentRatio > ratio {
            // Image is too wide, trim width
            newWidth = originalHeight * ratio
        } else {
            // Image is too tall, trim height
            newHeight = originalWidth / ratio
        }
        
        let x = (originalWidth - newWidth) / 2.0
        let y = (originalHeight - newHeight) / 2.0
        
        // Perform Crop
        guard let cgImage = image.cgImage?.cropping(to: CGRect(x: x, y: y, width: newWidth, height: newHeight)) else {
            return image
        }
        
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private func saveToCustomAlbum(imageData: Data, location: CLLocation?) {
        // (Use the exact same robust album code provided in the previous turn)
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            let albumName = "Boyfriend Camera"
            var albumPlaceholder: PHObjectPlaceholder?
            let fetchOptions = PHFetchOptions()
            fetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
            let collection = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
            
            if let existingAlbum = collection.firstObject {
                self.saveAsset(data: imageData, location: location, to: existingAlbum)
            } else {
                PHPhotoLibrary.shared().performChanges({
                    let createRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                    albumPlaceholder = createRequest.placeholderForCreatedAssetCollection
                }, completionHandler: { success, _ in
                    if success, let placeholder = albumPlaceholder {
                        let newCollection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholder.localIdentifier], options: nil).firstObject
                        if let album = newCollection {
                            self.saveAsset(data: imageData, location: location, to: album)
                        }
                    }
                })
            }
        }
    }
    
    private func saveAsset(data: Data, location: CLLocation?, to album: PHAssetCollection) {
        PHPhotoLibrary.shared().performChanges {
            let creationRequest = PHAssetCreationRequest.forAsset()
            creationRequest.addResource(with: .photo, data: data, options: nil)
            creationRequest.location = location
            guard let addAssetRequest = PHAssetCollectionChangeRequest(for: album) else { return }
            addAssetRequest.addAssets([creationRequest.placeholderForCreatedAsset!] as NSArray)
        }
    }

    // MARK: - HARDWARE DETECTION (The "Real" 1x and 5x Fix)

    private func setupCamera() {
        session.beginConfiguration()
        // FIX: Use .photo preset. This uses the full 4:3 sensor, not the 16:9 video crop.
        session.sessionPreset = .photo
        
        // 1. Discovery
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .back)
        // Prefer the wide camera device as default
        let wide = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
        let ultra = discovery.devices.first(where: { $0.deviceType == .builtInUltraWideCamera })
        let tele = discovery.devices.first(where: { $0.deviceType == .builtInTelephotoCamera })
        // Fallback to first available
        let device = wide ?? discovery.devices.first
        guard let selected = device else { session.commitConfiguration(); return }
        self.activeDevice = selected
        self.preferredLens = .wide
        
        // 2. Calculate UI-to-native zoom scaler for the selected lens
        // For wide lens, 1.0 UI should map to native 1.0
        self.zoomScaler = 1.0
        
        // 3. Detect Lens Switch Points (To find 3x vs 5x)
        let switchOverFactors = selected.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        
        telephotoThresholds.removeAll()
        for nativeFactor in switchOverFactors {
            let uiFactor = nativeFactor / self.zoomScaler
            if uiFactor > 1.2 {
                let clean = round(uiFactor)
                telephotoThresholds.append(clean)
            }
        }
        // Build buttons from thresholds
        var buttons: [CGFloat] = []
        if self.zoomScaler > 1.5 { buttons.append(0.5) }
        buttons.append(1.0)
        for t in telephotoThresholds.sorted() { if !buttons.contains(t) { buttons.append(t) } }
        if !buttons.contains(2.0) && buttons.contains(1.0) { buttons.append(2.0) }
        
        // Sort
        DispatchQueue.main.async {
            self.zoomButtons = buttons.sorted()
            self.minZoomFactor = self.zoomButtons.first ?? 1.0
            self.maxZoomFactor = selected.maxAvailableVideoZoomFactor / self.zoomScaler
        }
        
        // 4. Inputs/Outputs
        do {
            let input = try AVCaptureDeviceInput(device: selected)
            if session.canAddInput(input) { session.addInput(input) }
            deviceInput = input
        } catch { print("Input Error: \(error)") }
        
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.isHighResolutionCaptureEnabled = true
        }
        
        videoOutput.connection(with: .video)?.videoOrientation = .portrait
        
        session.commitConfiguration()
        session.startRunning()
        
        // Start at 1.0x (Main Lens)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.setZoom(1.0) }
    }
    
    // MARK: - Lens Switching
    func switchToUltraWideIfAvailable() {
        sessionQueue.async {
            let deviceTypes: [AVCaptureDevice.DeviceType] = [
                .builtInUltraWideCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera
            ]
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .back)
            guard let ultra = discovery.devices.first(where: { $0.deviceType == .builtInUltraWideCamera }) ?? discovery.devices.first else { return }
            self.switchToDevice(ultra, lens: .ultraWide, uiZoom: 0.5, scaler: 2.0)
        }
    }

    func switchToWideIfAvailable(targetUIZoom: CGFloat = 1.0) {
        sessionQueue.async {
            let deviceTypes: [AVCaptureDevice.DeviceType] = [
                .builtInWideAngleCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera
            ]
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .back)
            guard let wide = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? discovery.devices.first else { return }
            self.switchToDevice(wide, lens: .wide, uiZoom: targetUIZoom, scaler: 1.0)
        }
    }
    
    func switchToTelephotoIfAvailable(targetUIZoom: CGFloat) {
        sessionQueue.async {
            let deviceTypes: [AVCaptureDevice.DeviceType] = [
                .builtInTelephotoCamera,
                .builtInTripleCamera
            ]
            let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .back)
            guard let tele = discovery.devices.first(where: { $0.deviceType == .builtInTelephotoCamera }) ?? discovery.devices.first else { return }
            // For telephoto, UI scale should map so that threshold (e.g., 3x/5x) feels native. Use scaler = 1.0 for UI mapping continuity
            self.switchToDevice(tele, lens: .tele, uiZoom: targetUIZoom, scaler: 1.0)
        }
    }

    private func switchToDevice(_ newDevice: AVCaptureDevice, lens: BackLens, uiZoom: CGFloat, scaler: CGFloat) {
        session.beginConfiguration()
        // Remove old input
        if let input = self.deviceInput { session.removeInput(input) }
        do {
            let input = try AVCaptureDeviceInput(device: newDevice)
            if session.canAddInput(input) { session.addInput(input) }
            self.deviceInput = input
            self.activeDevice = newDevice
            self.preferredLens = lens
            self.zoomScaler = scaler
        } catch {
            print("Switch input error: \(error)")
        }
        session.commitConfiguration()
        // Update max/min and apply desired UI zoom after a tiny delay to let the session settle
        DispatchQueue.main.async {
            self.minZoomFactor = 0.5
            self.maxZoomFactor = newDevice.maxAvailableVideoZoomFactor / max(self.zoomScaler, 0.001)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.setZoom(uiZoom)
        }
    }
    
    // ... (Boilerplate Permissions/Vision logic same as before) ...
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
    
    func setFocus(point: CGPoint) { /* Same as previous response */ }
}
