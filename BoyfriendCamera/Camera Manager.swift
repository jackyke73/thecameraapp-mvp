import AVFoundation
import SwiftUI
import Combine
import Vision
import Photos // ✅ add

class CameraManager: NSObject, ObservableObject,
                     AVCaptureVideoDataOutputSampleBufferDelegate,
                     AVCapturePhotoCaptureDelegate {

    @Published var permissionGranted = false
    @Published var isPersonDetected = false
    @Published var capturedImage: UIImage?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cameraQueue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()

    private let bodyPoseRequest = VNDetectHumanBodyPoseRequest()

    // ✅ Store the location at the moment the shutter is pressed
    private var pendingLocation: CLLocation?

    override init() {
        super.init()
        checkPermissions()
    }

    // ✅ Capture photo + remember location
    func capturePhoto(location: CLLocation?) {
        pendingLocation = location

        sessionQueue.async {
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // --- your existing permission + setup logic ---
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
            DispatchQueue.main.async { self.permissionGranted = true }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.setupCamera()
                    DispatchQueue.main.async { self.permissionGranted = true }
                }
            }
        case .denied, .restricted:
            print("User denied camera permission")
        @unknown default:
            break
        }
    }

    private func setupCamera() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                print("No back camera found")
                self.session.commitConfiguration()
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) { self.session.addInput(input) }
            } catch {
                print("Error connecting camera: \(error.localizedDescription)")
                self.session.commitConfiguration()
                return
            }

            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
                let videoQueue = DispatchQueue(label: "videoQueue")
                self.videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
            }

            // ✅ Add photo output
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.isHighResolutionCaptureEnabled = true
            }

            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    // --- your existing Vision loop ---
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

    // ✅ Photo callback: save to Photos with location
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

        // Clear after use
        pendingLocation = nil
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
                request.location = location  // ✅ attach GPS here
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
