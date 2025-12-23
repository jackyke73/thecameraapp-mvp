import Foundation
import Vision
import CoreML
import CoreImage
import ImageIO
import CoreGraphics

struct CameraAIOutput: Equatable {
    let isPersonDetected: Bool
    let peopleCount: Int
    let expressions: [String]
    // normalized to preview space: x 0..1 L->R, y 0..1 T->B
    let nosePoint: CGPoint?
}

final class RollingLabelBuffer {
    private let size: Int
    private var arr: [String] = []
    init(size: Int) { self.size = max(3, size) }

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

final class CameraAIEngine {

    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private let faceRectRequest = VNDetectFaceRectanglesRequest()
    private let faceLandmarksRequest = VNDetectFaceLandmarksRequest()
    private let visionHandler = VNSequenceRequestHandler()

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

    private var frameCounter: Int = 0
    private let detectEveryNFrames: Int = 1

    private var emotionCounter: Int = 0
    private let emotionEveryNDetections: Int = 2

    private var isBusy: Bool = false
    private let maxFacesToClassify: Int = 2
    private var labelBuffers: [UUID: RollingLabelBuffer] = [:]

    private var lastOutput: CameraAIOutput = .init(
        isPersonDetected: false,
        peopleCount: 0,
        expressions: [],
        nosePoint: nil
    )

    func process(pixelBuffer: CVPixelBuffer,
                 orientation: CGImagePropertyOrientation = .right,
                 isMirrored: Bool = false) -> CameraAIOutput? {

        frameCounter += 1
        guard frameCounter % detectEveryNFrames == 0 else { return nil }
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }

        return autoreleasepool { () -> CameraAIOutput? in
            do {
                try visionHandler.perform([poseRequest, faceRectRequest],
                                          on: pixelBuffer,
                                          orientation: orientation)
            } catch {
                return nil
            }

            let poseObs = (poseRequest.results ?? [])
            let faces = (faceRectRequest.results as? [VNFaceObservation]) ?? []

            let poseCount = poseObs.count
            let faceCount = faces.count
            let peopleCount = max(poseCount, faceCount)
            let isDetected = peopleCount > 0

            // Largest face as primary
            let primaryFace = faces.max(by: { area($0.boundingBox) < area($1.boundingBox) })

            // 1) Nose from face landmarks / bbox
            var nosePoint: CGPoint? = nil
            if let primaryFace {
                if let p = noseFromLandmarks(pixelBuffer: pixelBuffer,
                                             face: primaryFace,
                                             orientation: orientation,
                                             isMirrored: isMirrored) {
                    nosePoint = p
                } else {
                    nosePoint = noseFromBoundingBox(face: primaryFace,
                                                    orientation: orientation,
                                                    isMirrored: isMirrored)
                }
            }

            // 2) Fallback: nose from body pose (THIS is what makes it reappear reliably)
            if nosePoint == nil, let firstPose = poseObs.first {
                nosePoint = noseFromBodyPose(pose: firstPose,
                                             orientation: orientation,
                                             isMirrored: isMirrored)
            }

            // Expressions
            var exprs: [String] = lastOutput.expressions
            emotionCounter += 1
            if emotionCounter % emotionEveryNDetections == 0 {
                exprs = classifyExpressions(pixelBuffer: pixelBuffer,
                                            faces: faces,
                                            orientation: orientation)
            }

            let output = CameraAIOutput(isPersonDetected: isDetected,
                                        peopleCount: peopleCount,
                                        expressions: exprs,
                                        nosePoint: nosePoint)

            // Return even if same; keeps UI “alive”
            lastOutput = output
            return output
        }
    }

    // MARK: - Coordinate helpers

    // Fixes your “right moves down / up moves right” mapping.
    // For orientation == .right, convert to preview space and rotate 90° CW:
    // (x, y) -> (1 - y, x)
    private func fix90Bug(_ p: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        guard orientation == .right else { return p }
        return CGPoint(x: 1.0 - p.y, y: p.x)
    }

    private func clamp01(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(1, p.x)), y: max(0, min(1, p.y)))
    }

    // Vision normalized uses bottom-left origin; preview uses top-left origin.
    private func visionToPreview(_ vision: CGPoint, orientation: CGImagePropertyOrientation, isMirrored: Bool) -> CGPoint {
        var p = CGPoint(x: vision.x, y: 1.0 - vision.y)  // to top-left
        p = fix90Bug(p, orientation: orientation)        
        if isMirrored == false { p.x = 1-p.x }
        if isMirrored == false { p.y = 1-p.y }
        if isMirrored {p.y = 1.0 - p.y}
        return clamp01(p)
    }

    // MARK: - Nose from face bbox

    private func noseFromBoundingBox(face: VNFaceObservation,
                                     orientation: CGImagePropertyOrientation,
                                     isMirrored: Bool) -> CGPoint? {
        let bb = face.boundingBox // Vision normalized bottom-left
        let noseVision = CGPoint(
            x: bb.midX,
            y: bb.minY + bb.height * 0.60
        )
        return visionToPreview(noseVision, orientation: orientation, isMirrored: isMirrored)
    }

    // MARK: - Nose from landmarks

    private func noseFromLandmarks(pixelBuffer: CVPixelBuffer,
                                   face: VNFaceObservation,
                                   orientation: CGImagePropertyOrientation,
                                   isMirrored: Bool) -> CGPoint? {

        faceLandmarksRequest.inputFaceObservations = [face]
        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: orientation,
                                                options: [:])
            try handler.perform([faceLandmarksRequest])
        } catch {
            return nil
        }

        guard let obs = faceLandmarksRequest.results?.first,
              let landmarks = obs.landmarks else { return nil }

        let pts = landmarks.noseCrest?.normalizedPoints
            ?? landmarks.nose?.normalizedPoints

        guard let points = pts, !points.isEmpty else { return nil }

        // choose a stable point along nose crest
        let tip = points.max(by: { $0.y < $1.y }) ?? points[points.count / 2]

        let bb = obs.boundingBox
        let visionX = bb.origin.x + tip.x * bb.size.width
        let visionY = bb.origin.y + tip.y * bb.size.height

        return visionToPreview(CGPoint(x: visionX, y: visionY),
                               orientation: orientation,
                               isMirrored: isMirrored)
    }

    // MARK: - Nose from body pose (fallback)

    private func noseFromBodyPose(pose: VNHumanBodyPoseObservation,
                                  orientation: CGImagePropertyOrientation,
                                  isMirrored: Bool) -> CGPoint? {
        do {
            let nose = try pose.recognizedPoint(.nose)
            guard nose.confidence > 0.2 else { return nil }
            // nose.location is Vision normalized (bottom-left)
            return visionToPreview(nose.location, orientation: orientation, isMirrored: isMirrored)
        } catch {
            return nil
        }
    }

    // MARK: - Expressions

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
            let (rawLabel, conf) = runEmotionModel(model: model,
                                                  pixelBuffer: pixelBuffer,
                                                  roi: face.boundingBox,
                                                  orientation: orientation)

            let normalized = normalizeLabel(rawLabel, confidence: conf)

            let id = face.uuid
            let buf = labelBuffers[id] ?? RollingLabelBuffer(size: 7)
            buf.push(normalized)
            labelBuffers[id] = buf
            results.append(buf.mode())
        }

        if labelBuffers.count > 16 {
            labelBuffers = Dictionary(uniqueKeysWithValues: Array(labelBuffers.prefix(12)))
        }
        return results
    }

    private func runEmotionModel(model: VNCoreMLModel,
                                 pixelBuffer: CVPixelBuffer,
                                 roi: CGRect,
                                 orientation: CGImagePropertyOrientation) -> (String, Float) {

        var bestLabel = "Unknown"
        var bestConf: Float = 0

        let request = VNCoreMLRequest(model: model) { req, _ in
            guard let obs = req.results as? [VNClassificationObservation],
                  let top = obs.first else { return }
            bestLabel = top.identifier
            bestConf = top.confidence
        }
        request.imageCropAndScaleOption = .centerCrop
        request.regionOfInterest = roi

        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                orientation: orientation,
                                                options: [:])
            try handler.perform([request])
        } catch {
            return ("Unknown", 0)
        }

        return (bestLabel, bestConf)
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
