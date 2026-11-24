import ARKit
import CoreVideo
import simd

struct DepthProjector {
    static func project(frame: ARFrame, stride: Int = 2) -> [WorldSample] {
        guard let depthData = frame.sceneDepth else { return [] }
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
                guard depth.isFinite, depth >= 0.25, depth <= 4.5 else { continue }
                let confidence = confidenceRow.map { Int($0[u]) } ?? 1
                guard confidence >= ARConfidenceLevel.medium.rawValue else { continue }

                // ARCamera uses a right-handed camera space looking along negative Z.
                let cameraPoint = SIMD4<Float>(
                    (Float(u) - cx) * depth / fx,
                    (cy - Float(v)) * depth / fy,
                    -depth,
                    1
                )
                let world = cameraToWorld * cameraPoint
                output.append(WorldSample(
                    position: SIMD3<Float>(world.x, world.y, world.z),
                    weight: confidence == ARConfidenceLevel.high.rawValue ? 2 : 1
                ))
            }
        }
        return output
    }
}
