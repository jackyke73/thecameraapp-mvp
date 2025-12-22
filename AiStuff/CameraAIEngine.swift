import Foundation
import Vision
import CoreML
import CoreImage
import ImageIO   // for CGImagePropertyOrientation

// MARK: - AI Output
struct CameraAIOutput: Equatable {
    let isPersonDetected: Bool
    let peopleCount: Int
    let expressions: [String]
}

// MARK: - Rolling label smoother
final class RollingLabelBuffer {
    private let size: Int
    private var arr: [String] = []

    init(size: Int) {
        self.size = max(3, size)
    }

    func push(_ s: String) {
        arr.append(s)
        if arr.count > size { arr.removeFirst(arr.count - size) }
    }

    func mode() -> String {
        guard !arr.isEmpty else { return "Neutral" }
        var counts: [String: Int] = [:]
        for s in arr { counts[s, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key ?? (arr.last ?? "Neutral")
    }
}

// MARK: - AI Engine
final class CameraAIEngine {

    // Vision requests
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private let faceRectRequest = VNDetectFaceRectanglesRequest()
    private let visionHandler = VNSequenceRequestHandler()

    // CoreML model
    private lazy var expressionModel: VNCoreMLModel? = {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let coreML = try CNNEmotions_2(configuration: config).model
            return try VNCoreMLModel(for: coreML)
        } catch {
            print("⚠️ Failed to load CNNEmotions model:", error)
            return nil
        }
    }()

    // Throttling
    private var frameCounter: Int = 0
    private let detectEveryNFrames: Int = 6

    private var emotionCounter: Int = 0
    private let emotionEveryNDetections: Int = 2

    private var isBusy: Bool = false

    // Limits
    private let maxFacesToClassify: Int = 2

    // Smoothing per face
    private var labelBuffers: [UUID: RollingLabelBuffer] = [:]

    // Cache last output
    private var lastOutput: CameraAIOutput = .init(isPersonDetected: false, peopleCount: 0, expressions: [])

    func process(pixelBuffer: CVPixelBuffer,
                 orientation: CGImagePropertyOrientation = .right) -> CameraAIOutput? {

        frameCounter += 1
        guard frameCounter % detectEveryNFrames == 0 else { return nil }
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }

        // ✅ IMPORTANT: return the autoreleasepool value (typed as CameraAIOutput?)
        return autoreleasepool { () -> CameraAIOutput? in
            do {
                try visionHandler.perform([poseRequest, faceRectRequest],
                                          on: pixelBuffer,
                                          orientation: orientation)
            } catch {
                return nil
            }

            let poseCount = poseRequest.results?.count ?? 0
            let faces = (faceRectRequest.results as? [VNFaceObservation]) ?? []
            let faceCount = faces.count

            let peopleCount = max(poseCount, faceCount)
            let isDetected = peopleCount > 0

            // run emotion less frequently (expensive)
            var exprs: [String] = lastOutput.expressions
            emotionCounter += 1
            if emotionCounter % emotionEveryNDetections == 0 {
                exprs = classifyExpressions(pixelBuffer: pixelBuffer,
                                            faces: faces,
                                            orientation: orientation)
            }

            let output = CameraAIOutput(isPersonDetected: isDetected,
                                        peopleCount: peopleCount,
                                        expressions: exprs)

            if output != lastOutput {
                lastOutput = output
                return output
            } else {
                return nil
            }
        }
    }

    // MARK: - Expression inference
    private func classifyExpressions(pixelBuffer: CVPixelBuffer,
                                     faces: [VNFaceObservation],
                                     orientation: CGImagePropertyOrientation) -> [String] {

        guard !faces.isEmpty else { return [] }
        guard let model = expressionModel else {
            return Array(repeating: "Unknown", count: min(faces.count, maxFacesToClassify))
        }

        let targets = faces.sorted { area($0.boundingBox) > area($1.boundingBox) }
        let chosen = Array(targets.prefix(maxFacesToClassify))

        var results: [String] = []
        for face in chosen {
            guard let faceCrop = cropFaceCIImage(from: pixelBuffer, faceBoundingBox: face.boundingBox) else {
                results.append("Unknown")
                continue
            }

            let (rawLabel, conf) = runEmotionModel(model: model, faceCrop: faceCrop, orientation: orientation)
            let normalized = normalizeLabel(rawLabel, confidence: conf)

            let id = face.uuid
            let buf = labelBuffers[id] ?? RollingLabelBuffer(size: 7)
            buf.push(normalized)
            labelBuffers[id] = buf

            results.append(buf.mode())
        }

        // cap buffer growth
        if labelBuffers.count > 16 {
            let trimmed = Array(labelBuffers.prefix(12))
            labelBuffers = Dictionary(uniqueKeysWithValues: trimmed)
        }

        return results
    }

    private func runEmotionModel(model: VNCoreMLModel,
                                 faceCrop: CIImage,
                                 orientation: CGImagePropertyOrientation) -> (String, Float) {

        var bestLabel = "Unknown"
        var bestConf: Float = 0

        let request = VNCoreMLRequest(model: model) { req, _ in
            guard let obs = req.results as? [VNClassificationObservation],
                  let top = obs.first else { return }
            bestLabel = top.identifier
            bestConf = top.confidence
        }

        request.imageCropAndScaleOption = VNImageCropAndScaleOption.scaleFill

        let handler = VNImageRequestHandler(ciImage: faceCrop, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ("Unknown", 0)
        }

        return (bestLabel, bestConf)
    }

    // MARK: - Helpers
    private func cropFaceCIImage(from pixelBuffer: CVPixelBuffer,
                                 faceBoundingBox: CGRect) -> CIImage? {

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = ciImage.extent.width
        let height = ciImage.extent.height

        let x = faceBoundingBox.origin.x * width
        let y = (1.0 - faceBoundingBox.origin.y - faceBoundingBox.size.height) * height
        let w = faceBoundingBox.size.width * width
        let h = faceBoundingBox.size.height * height

        let rect = CGRect(x: x, y: y, width: w, height: h).integral
        guard rect.width > 10, rect.height > 10 else { return nil }

        return ciImage.cropped(to: rect)
    }

    private func normalizeLabel(_ raw: String, confidence: Float) -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if confidence < 0.60 { return "Neutral" }

        if id.contains("happy") { return "Happy" }
        if id.contains("neutral") { return "Neutral" }
        if id.contains("surpris") { return "Surprised" }
        if id.contains("ang") { return "Angry" }
        if id.contains("sad") { return "Sad" }
        if id.contains("fear") { return "Fear" }
        if id.contains("disgust") { return "Disgust" }

        return raw.capitalized
    }

    private func area(_ bb: CGRect) -> CGFloat {
        max(0, bb.width * bb.height)
    }
}
