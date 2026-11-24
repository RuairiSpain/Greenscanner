import ARKit
import CoreVideo
import simd

struct DepthProjector {
    /// LiDAR noise grows with range, so far samples are rejected and mid-range samples are down-weighted.
    static let maximumDepth: Float = 3.5

    /// Back-projects a depth pixel into ARKit camera space (x right, y up, camera looks along -z).
    static func cameraPoint(u: Float, v: Float, depth: Float, fx: Float, fy: Float, cx: Float, cy: Float) -> SIMD3<Float> {
        SIMD3<Float>((u - cx) * depth / fx, (cy - v) * depth / fy, -depth)
    }

    /// Surfaces seen at a grazing angle give noisier depth. `rayY` is the vertical component of the
    /// unit viewing ray; a ray straight down gives weight 1.
    static func incidenceWeight(rayY: Float) -> Float {
        max(0.2, abs(rayY))
    }

    /// Full-range YCbCr (as delivered in ARFrame.capturedImage) to RGB in 0...1.
    static func rgb(y: UInt8, cb: UInt8, cr: UInt8) -> SIMD3<Float> {
        let yf = Float(y), cbf = Float(cb) - 128, crf = Float(cr) - 128
        return SIMD3<Float>((yf + 1.402 * crf) / 255,
                            (yf - 0.344136 * cbf - 0.714136 * crf) / 255,
                            (yf + 1.772 * cbf) / 255).clamped01
    }

    static func rangeWeight(depth: Float) -> Float {
        let ratio = 1.5 / max(depth, 0.25)
        return min(1, ratio * ratio)
    }

    static func project(frame: ARFrame, stride: Int = 2, smoothed: Bool = false, withColour: Bool = false) -> [WorldSample] {
        guard let depthData = (smoothed ? frame.smoothedSceneDepth : nil) ?? frame.sceneDepth else { return [] }
        let depthMap = depthData.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return [] }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return [] }

        guard CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess else { return [] }
        let candidateConfidenceMap = depthData.confidenceMap
        let confidenceMap: CVPixelBuffer? = candidateConfidenceMap.flatMap {
            guard CVPixelBufferGetWidth($0) == width,
                  CVPixelBufferGetHeight($0) == height,
                  CVPixelBufferLockBaseAddress($0, .readOnly) == kCVReturnSuccess else { return nil }
            return $0
        }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }

        // Optional colour lookup from the camera image (the depth map and image share one sensor orientation).
        let image = frame.capturedImage
        var imageLocked = false
        if withColour,
           CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
           CVPixelBufferGetPlaneCount(image) == 2,
           CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess {
            imageLocked = true
        }
        defer { if imageLocked { CVPixelBufferUnlockBaseAddress(image, .readOnly) } }
        let lumaBase = imageLocked ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : nil
        let chromaBase = imageLocked ? CVPixelBufferGetBaseAddressOfPlane(image, 1) : nil
        let lumaStride = imageLocked ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : 0
        let chromaStride = imageLocked ? CVPixelBufferGetBytesPerRowOfPlane(image, 1) : 0
        let imageWidth = CVPixelBufferGetWidth(image)
        let imageHeight = CVPixelBufferGetHeight(image)

        let imageSize = frame.camera.imageResolution
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }
        let scaleX = Float(width) / Float(imageSize.width)
        let scaleY = Float(height) / Float(imageSize.height)
        let k = frame.camera.intrinsics
        let fx = k[0][0] * scaleX
        let fy = k[1][1] * scaleY
        let cx = k[2][0] * scaleX
        let cy = k[2][1] * scaleY
        guard fx > 0, fy > 0 else { return [] }

        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceBytesPerRow = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let cameraToWorld = frame.camera.transform
        let sampleStride = max(1, stride)
        var output: [WorldSample] = []
        output.reserveCapacity(width * height / (sampleStride * sampleStride))

        for v in Swift.stride(from: 0, to: height, by: sampleStride) {
            let depthRow = depthBase.advanced(by: v * depthBytesPerRow).assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase?.advanced(by: v * confidenceBytesPerRow).assumingMemoryBound(to: UInt8.self)
            for u in Swift.stride(from: 0, to: width, by: sampleStride) {
                let depth = depthRow[u]
                guard depth.isFinite, depth >= 0.25, depth <= maximumDepth else { continue }
                let confidence = confidenceRow.map { Int($0[u]) } ?? 1
                guard confidence >= ARConfidenceLevel.medium.rawValue else { continue }

                // ARCamera uses a right-handed camera space looking along negative Z.
                let point = cameraPoint(u: Float(u), v: Float(v), depth: depth, fx: fx, fy: fy, cx: cx, cy: cy)
                let world = cameraToWorld * SIMD4<Float>(point.x, point.y, point.z, 1)
                let rayY = (world.y - cameraToWorld.columns.3.y) / max(simd_length(point), 0.001)
                var colour: SIMD3<Float>?
                if let lumaBase, let chromaBase {
                    let px = min(imageWidth - 1, u * imageWidth / width)
                    let py = min(imageHeight - 1, v * imageHeight / height)
                    let y = lumaBase.assumingMemoryBound(to: UInt8.self)[py * lumaStride + px]
                    let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
                    let offset = (py / 2) * chromaStride + (px / 2) * 2
                    colour = rgb(y: y, cb: chroma[offset], cr: chroma[offset + 1])
                }
                output.append(WorldSample(
                    position: SIMD3<Float>(world.x, world.y, world.z),
                    weight: (confidence == ARConfidenceLevel.high.rawValue ? 2 : 1) * rangeWeight(depth: depth)
                    * incidenceWeight(rayY: rayY),
                    colour: colour
                ))
            }
        }
        return output
    }
}

private extension SIMD3 where Scalar == Float {
    var clamped01: SIMD3<Float> {
        SIMD3<Float>(Swift.min(Swift.max(x, 0), 1), Swift.min(Swift.max(y, 0), 1), Swift.min(Swift.max(z, 0), 1))
    }
}
