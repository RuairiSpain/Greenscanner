import Foundation
import CoreGraphics
import UIKit
import simd

/// A low-resolution top-down colour image of the green, stored with the scan.
struct GreenImage: Codable, Sendable {
    let width: Int
    let height: Int
    /// Edge length of one pixel, in metres.
    let texelSize: Float
    /// Map-local position of the image's top-left corner (x, z).
    let minX: Float
    let minZ: Float
    let png: Data

    var uiImage: UIImage? { UIImage(data: png) }
    var widthMetres: Float { Float(width) * texelSize }
    var heightMetres: Float { Float(height) * texelSize }
}

/// Averages camera colours onto a ground grid. Only ground colours are kept, at 10 cm resolution, so people and
/// objects above the ground are excluded and no raw photos are stored.
final class GreenTextureAccumulator: @unchecked Sendable {
    static let texelSize: Float = 0.1
    /// Samples more than this far above or below the first edge point are not ground.
    static let groundBand: Float = 0.8

    struct Snapshot: Codable, Sendable {
        let minX: Float
        let minZ: Float
        let width: Int
        let height: Int
        let origin: SIMD3<Float>
        /// Four values per texel: red, green and blue sums and the weight.
        let sums: [Float]
    }

    private let lock = NSLock()
    private var scanID: UUID?
    private var origin = SIMD3<Float>.zero
    private var minX: Float = 0
    private var minZ: Float = 0
    private var width = 0
    private var height = 0
    private var sums: [Float] = []

    func configure(polygon: [SIMD2<Float>], origin: SIMD3<Float>, scanID: UUID) {
        lock.lock(); defer { lock.unlock() }
        self.scanID = scanID
        self.origin = origin
        guard let bounds = GreenGeometry.bounds(polygon) else { width = 0; height = 0; sums = []; return }
        let margin = GreenMapAccumulator.bandWidth
        minX = floor((bounds.min.x - margin) / Self.texelSize) * Self.texelSize
        minZ = floor((bounds.min.y - margin) / Self.texelSize) * Self.texelSize
        width = Int(ceil((bounds.max.x + margin - minX) / Self.texelSize)) + 1
        height = Int(ceil((bounds.max.y + margin - minZ) / Self.texelSize)) + 1
        sums = [Float](repeating: 0, count: width * height * 4)
    }

    func add(_ samples: [WorldSample], scanID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard scanID == self.scanID, width > 0 else { return }
        for sample in samples {
            guard let colour = sample.colour else { continue }
            let local = sample.position - origin
            guard abs(local.y) <= Self.groundBand else { continue }
            let ix = Int(floor((local.x - minX) / Self.texelSize))
            let iz = Int(floor((local.z - minZ) / Self.texelSize))
            guard ix >= 0, ix < width, iz >= 0, iz < height else { continue }
            let base = (iz * width + ix) * 4
            sums[base] += colour.x * sample.weight
            sums[base + 1] += colour.y * sample.weight
            sums[base + 2] += colour.z * sample.weight
            sums[base + 3] += sample.weight
        }
    }

    /// Average colour (0...1) at a map-local position, or nil if nothing was seen there.
    func colour(atLocal point: SIMD2<Float>) -> SIMD3<Float>? {
        lock.lock(); defer { lock.unlock() }
        let ix = Int(floor((point.x - minX) / Self.texelSize))
        let iz = Int(floor((point.y - minZ) / Self.texelSize))
        guard ix >= 0, ix < width, iz >= 0, iz < height else { return nil }
        let base = (iz * width + ix) * 4
        let weight = sums[base + 3]
        guard weight > 0 else { return nil }
        return SIMD3<Float>(sums[base], sums[base + 1], sums[base + 2]) / weight
    }

    func snapshot() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard width > 0 else { return nil }
        return Snapshot(minX: minX, minZ: minZ, width: width, height: height, origin: origin, sums: sums)
    }

    func restore(_ snapshot: Snapshot, scanID: UUID) {
        lock.lock(); defer { lock.unlock() }
        self.scanID = scanID
        origin = snapshot.origin
        minX = snapshot.minX; minZ = snapshot.minZ
        width = snapshot.width; height = snapshot.height
        sums = snapshot.sums
    }

    /// PNG of the averaged colours; texels never seen are transparent.
    func makeImage() -> GreenImage? {
        lock.lock()
        let width = self.width, height = self.height, sums = self.sums, minX = self.minX, minZ = self.minZ
        lock.unlock()
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var seen = 0
        for texel in 0..<(width * height) {
            let weight = sums[texel * 4 + 3]
            guard weight > 0.5 else { continue }
            for channel in 0..<3 {
                rgba[texel * 4 + channel] = UInt8((sums[texel * 4 + channel] / weight * 255).clamped(to: 0...255))
            }
            rgba[texel * 4 + 3] = 255
            seen += 1
        }
        guard seen > 0, let png = Self.png(rgba: rgba, width: width, height: height) else { return nil }
        return GreenImage(width: width, height: height, texelSize: Self.texelSize, minX: minX, minZ: minZ, png: png)
    }

    static func png(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image).pngData()
    }
}
