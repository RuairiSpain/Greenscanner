import Foundation
import simd

/// Accumulates depth samples inside a green outline into a fixed grid and tracks how well each
/// cell has been observed, plus a drift estimate from revisited cells.
final class GreenMapAccumulator: @unchecked Sendable {
    struct Cell {
        var sumWeight: Float
        var sumWeightedHeight: Float
        var count: Int
        var minRange: Float
        var lastTime: Double
        var mean: Float { sumWeightedHeight / max(sumWeight, 0.001) }
    }

    struct Summary: Sendable {
        let good: Int
        let weak: Int
        let total: Int
        let driftMillimetres: Double?
        var coverage: Double { Double(good + weak) / Double(max(total, 1)) }
        var goodShare: Double { good + weak == 0 ? 0 : Double(good) / Double(good + weak) }
    }

    static let cellSize: Float = 0.2
    /// Observations from farther than this are flagged as weak (amber).
    static let goodRange: Float = 2.5
    static let minimumObservations = 3

    private let lock = NSLock()
    private var scanID: UUID?
    private var polygon: [SIMD2<Float>] = []
    private var origin = SIMD3<Float>.zero
    private var cells: [SIMD2<Int32>: Cell] = [:]
    private var insideCache: [SIMD2<Int32>: Bool] = [:]
    private var totalInside = 0
    private var driftSamples: [Float] = []

    func configure(polygon: [SIMD2<Float>], origin: SIMD3<Float>, scanID: UUID) {
        lock.lock(); defer { lock.unlock() }
        self.polygon = polygon
        self.origin = origin
        self.scanID = scanID
        cells.removeAll(keepingCapacity: true)
        insideCache.removeAll(keepingCapacity: true)
        driftSamples.removeAll()
        totalInside = 0
        guard let bounds = GreenGeometry.bounds(polygon) else { return }
        let size = Self.cellSize
        let x0 = Int32(floor(bounds.min.x / size)), x1 = Int32(floor(bounds.max.x / size))
        let z0 = Int32(floor(bounds.min.y / size)), z1 = Int32(floor(bounds.max.y / size))
        guard x1 >= x0, z1 >= z0 else { return }
        for ix in x0...x1 {
            for iz in z0...z1 {
                let key = SIMD2<Int32>(ix, iz)
                if isInside(key) { totalInside += 1 }
            }
        }
    }

    private func isInside(_ key: SIMD2<Int32>) -> Bool {
        if let cached = insideCache[key] { return cached }
        let size = Self.cellSize
        let centre = SIMD2<Float>((Float(key.x) + 0.5) * size, (Float(key.y) + 0.5) * size)
        let inside = GreenGeometry.contains(polygon, point: centre)
        insideCache[key] = inside
        return inside
    }

    func ingest(_ samples: [WorldSample], camera: SIMD3<Float>, timestamp: Double, scanID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard scanID == self.scanID, polygon.count >= 3 else { return }
        let size = Self.cellSize

        var bins: [SIMD2<Int32>: (heights: [Float], weight: Float)] = [:]
        for sample in samples {
            let x = sample.position.x - origin.x
            let z = sample.position.z - origin.z
            let key = SIMD2<Int32>(Int32(floor(x / size)), Int32(floor(z / size)))
            guard isInside(key) else { continue }
            var bin = bins[key] ?? ([], 0)
            bin.heights.append(sample.position.y - origin.y)
            bin.weight += sample.weight
            bins[key] = bin
        }

        let cameraLocal = camera - origin
        for (key, bin) in bins {
            guard bin.heights.count >= 3 else { continue }
            let height = median(bin.heights)
            let weight = min(3, bin.weight / Float(bin.heights.count))
            let centreX = (Float(key.x) + 0.5) * size
            let centreZ = (Float(key.y) + 0.5) * size
            let range = simd_length(SIMD3<Float>(cameraLocal.x - centreX, cameraLocal.y - height, cameraLocal.z - centreZ))

            var cell = cells[key] ?? Cell(sumWeight: 0, sumWeightedHeight: 0, count: 0,
                                          minRange: .greatestFiniteMagnitude, lastTime: timestamp)
            if cell.count >= Self.minimumObservations {
                let difference = height - cell.mean
                if abs(difference) > 0.08 { continue }
                // A revisit well after the first pass measures how far tracking has drifted.
                if timestamp - cell.lastTime > 10 {
                    driftSamples.append(difference)
                    if driftSamples.count > 600 { driftSamples.removeFirst(100) }
                }
            }
            cell.sumWeight += weight
            cell.sumWeightedHeight += height * weight
            cell.count += 1
            cell.minRange = min(cell.minRange, range)
            cell.lastTime = timestamp
            cells[key] = cell
        }
    }

    func summary() -> Summary {
        lock.lock(); defer { lock.unlock() }
        var good = 0, weak = 0
        for cell in cells.values where cell.count >= Self.minimumObservations {
            if cell.minRange <= Self.goodRange { good += 1 } else { weak += 1 }
        }
        var drift: Double?
        if driftSamples.count >= 20 {
            drift = Double(median(driftSamples.map { abs($0) })) * 1000
        }
        return Summary(good: good, weak: weak, total: totalInside, driftMillimetres: drift)
    }

    /// Tile centres (local metres) for rendering and the minimap.
    func tiles() -> (good: [MapTile], weak: [MapTile]) {
        lock.lock(); defer { lock.unlock() }
        let size = Self.cellSize
        var good: [MapTile] = [], weak: [MapTile] = []
        for (key, cell) in cells where cell.count >= Self.minimumObservations {
            let tile = MapTile(x: (Float(key.x) + 0.5) * size, z: (Float(key.y) + 0.5) * size, y: cell.mean)
            if cell.minRange <= Self.goodRange { good.append(tile) } else { weak.append(tile) }
        }
        return (good, weak)
    }

    func exportCells() -> [MapCell] {
        lock.lock(); defer { lock.unlock() }
        return cells.compactMap { key, cell in
            guard cell.count >= Self.minimumObservations else { return nil }
            return MapCell(ix: Int(key.x), iz: Int(key.y), height: cell.mean,
                           observations: cell.count, bestRange: cell.minRange)
        }.sorted { ($0.iz, $0.ix) < ($1.iz, $1.ix) }
    }
}
