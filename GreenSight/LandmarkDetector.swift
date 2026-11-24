import Foundation
import Vision
import CoreImage

final class LandmarkDetector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "greensight.landmark-detector", qos: .userInitiated)
    private var busy = false
    private let lock = NSLock()

    func detect(in pixelBuffer: CVPixelBuffer, mode: DetectionMode, completion: @escaping (LandmarkCandidate?) -> Void) {
        lock.lock()
        guard !busy else { lock.unlock(); return }
        busy = true
        lock.unlock()

        queue.async { [weak self] in
            defer {
                self?.lock.lock(); self?.busy = false; self?.lock.unlock()
            }
            let request = VNDetectContoursRequest()
            request.contrastAdjustment = mode == .ball ? 1.4 : 1.8
            request.detectsDarkOnLight = mode == .cup
            request.maximumImageDimension = 512
            // Keep detections in the captured image's native coordinates. ARFrame.displayTransform
            // performs the orientation and viewport crop when the candidate is shown onscreen.
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                try handler.perform([request])
                guard let observation = request.results?.first else {
                    completion(nil); return
                }
                var best: LandmarkCandidate?
                for contour in observation.topLevelContours {
                    let box = contour.normalizedPath.boundingBoxOfPath
                    let width = Double(box.width)
                    let height = Double(box.height)
                    guard width > 0.008, height > 0.008, width < 0.22, height < 0.22 else { continue }
                    let circularity = min(width, height) / max(width, height)
                    guard circularity > 0.58 else { continue }
                    let sizeScore = 1 - min(1, abs((width + height) * 0.5 - 0.045) / 0.12)
                    let score = 0.75 * circularity + 0.25 * sizeScore
                    let candidate = LandmarkCandidate(
                        normalizedCenter: CGPoint(x: box.midX, y: box.midY),
                        confidence: score
                    )
                    if candidate.confidence > (best?.confidence ?? -Double.infinity) { best = candidate }
                }
                completion(best)
            } catch {
                completion(nil)
            }
        }
    }
}
