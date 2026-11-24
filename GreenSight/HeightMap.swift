import Foundation
import simd

final class HeightMapAccumulator: @unchecked Sendable {
    private struct CellAccumulator {
        var estimates: [(height: Float, weight: Float)] = []
        var nextReplacementIndex = 0

        mutating func append(height: Float, weight: Float) {
            if estimates.count < 40 {
                estimates.append((height, weight))
                return
            }
            estimates[nextReplacementIndex] = (height, weight)
            nextReplacementIndex = (nextReplacementIndex + 1) % estimates.count
        }
    }

    private let lock = NSLock()
    private let cellSize: Float
    private let corridorHalfWidth: Float
    private var basis: GreenBasis?
    private var scanID: UUID?
    private var puttLength: Float = 0
    private var cells: [SIMD2<Int32>: CellAccumulator] = [:]
    private(set) var acceptedFrames = 0

    init(cellSize: Float = 0.03, corridorHalfWidth: Float = 0.75) {
        self.cellSize = cellSize
        self.corridorHalfWidth = corridorHalfWidth
    }

    func reset(ball: SIMD3<Float>, cup: SIMD3<Float>, scanID: UUID = UUID()) -> Bool {
        guard let newBasis = GreenBasis(ball: ball, cup: cup) else { return false }
        lock.lock()
        defer { lock.unlock() }
        basis = newBasis
        self.scanID = scanID
        puttLength = simd_length(SIMD2<Float>(cup.x - ball.x, cup.z - ball.z))
        cells.removeAll(keepingCapacity: true)
        acceptedFrames = 0
        return true
    }

    func ingest(_ samples: [WorldSample], scanID: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let basis, scanID == nil || scanID == self.scanID else { return }

        var frameBins: [SIMD2<Int32>: [(Float, Float)]] = [:]
        frameBins.reserveCapacity(samples.count / 2)

        for sample in samples {
            let p = basis.local(sample.position)
            guard abs(p.x) <= corridorHalfWidth,
                  p.y >= -0.35,
                  p.y <= puttLength + 0.45,
                  p.z >= -0.45,
                  p.z <= 0.45 else { continue }
            let key = SIMD2<Int32>(Int32(floor(p.x / cellSize)), Int32(floor(p.y / cellSize)))
            frameBins[key, default: []].append((p.z, sample.weight))
        }

        guard frameBins.count >= 8 else { return }
        for (key, observations) in frameBins {
            // One robust estimate per frame prevents adjacent pixels from appearing independent.
            let heights = observations.map { $0.0 }
            let estimate = median(heights)
            let weight = min(3, observations.map { $0.1 }.reduce(0, +) / Float(max(observations.count, 1)))
            var cell = cells[key, default: CellAccumulator()]
            cell.append(height: estimate, weight: weight)
            cells[key] = cell
        }
        acceptedFrames += 1
    }

    func snapshot(scanID: UUID? = nil) -> HeightMapSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard (scanID == nil || scanID == self.scanID), !cells.isEmpty else { return .empty }

        var output: [HeightCell] = []
        output.reserveCapacity(cells.count)
        for (key, accumulator) in cells where accumulator.estimates.count >= 2 {
            let heights = accumulator.estimates.map { $0.height }
            let centre = median(heights)
            let deviations = heights.map { abs($0 - centre) }
            let mad = max(median(deviations), 0.001)
            let retained = accumulator.estimates.filter { abs($0.height - centre) <= 3.5 * mad }
            guard !retained.isEmpty else { continue }
            let totalWeight = retained.map { $0.weight }.reduce(0, +)
            let mean = retained.reduce(Float.zero) { $0 + $1.height * $1.weight } / max(totalWeight, 0.001)
            let variance = retained.reduce(Float.zero) { $0 + pow($1.height - mean, 2) } / Float(retained.count)
            output.append(HeightCell(x: Int(key.x), y: Int(key.y), height: mean, variance: variance, observations: retained.count))
        }

        guard !output.isEmpty else { return .empty }
        let xValues = output.map(\.x)
        let yValues = output.map(\.y)
        let expected = max(1, Int((puttLength + 0.8) * (corridorHalfWidth * 2) / (cellSize * cellSize)))
        let coverage = min(1, Double(output.count) / Double(expected))
        return HeightMapSnapshot(
            cellSize: cellSize,
            cells: output,
            minX: xValues.min() ?? 0,
            maxX: xValues.max() ?? 0,
            minY: yValues.min() ?? 0,
            maxY: yValues.max() ?? 0,
            coverage: coverage
        )
    }

    func currentBasis(scanID: UUID? = nil) -> GreenBasis? {
        lock.lock(); defer { lock.unlock() }
        guard scanID == nil || scanID == self.scanID else { return nil }
        return basis
    }
}

struct GreenSurface: Sendable {
    let snapshot: HeightMapSnapshot
    private let lookup: [SIMD2<Int32>: HeightCell]
    private let gradientLookup: [SIMD2<Int32>: SIMD2<Double>]

    init(snapshot: HeightMapSnapshot) {
        self.snapshot = snapshot
        let cellsByKey = Dictionary(uniqueKeysWithValues: snapshot.cells.map {
            (SIMD2<Int32>(Int32($0.x), Int32($0.y)), $0)
        })
        lookup = cellsByKey

        let size = Double(snapshot.cellSize)
        var gradients: [SIMD2<Int32>: SIMD2<Double>] = [:]
        gradients.reserveCapacity(cellsByKey.count)
        for (key, cell) in cellsByKey {
            let centre = Double(cell.height)
            let left = cellsByKey[SIMD2<Int32>(key.x - 1, key.y)].map { Double($0.height) }
            let right = cellsByKey[SIMD2<Int32>(key.x + 1, key.y)].map { Double($0.height) }
            let down = cellsByKey[SIMD2<Int32>(key.x, key.y - 1)].map { Double($0.height) }
            let up = cellsByKey[SIMD2<Int32>(key.x, key.y + 1)].map { Double($0.height) }

            let dx: Double?
            if let left, let right { dx = (right - left) / (2 * size) }
            else if let left { dx = (centre - left) / size }
            else if let right { dx = (right - centre) / size }
            else { dx = nil }

            let dy: Double?
            if let down, let up { dy = (up - down) / (2 * size) }
            else if let down { dy = (centre - down) / size }
            else if let up { dy = (up - centre) / size }
            else { dy = nil }

            if let dx, let dy { gradients[key] = SIMD2<Double>(dx, dy) }
        }
        gradientLookup = gradients
    }

    func height(at point: SIMD2<Double>) -> Double? {
        let size = Double(snapshot.cellSize)
        let gx = point.x / size
        let gy = point.y / size
        let x0 = Int32(floor(gx))
        let y0 = Int32(floor(gy))
        let tx = gx - Double(x0)
        let ty = gy - Double(y0)
        let k00 = SIMD2<Int32>(x0, y0)
        let k10 = SIMD2<Int32>(x0 + 1, y0)
        let k01 = SIMD2<Int32>(x0, y0 + 1)
        let k11 = SIMD2<Int32>(x0 + 1, y0 + 1)
        if let h00 = lookup[k00].map({ Double($0.height) }),
           let h10 = lookup[k10].map({ Double($0.height) }),
           let h01 = lookup[k01].map({ Double($0.height) }),
           let h11 = lookup[k11].map({ Double($0.height) }) {
            return (1 - ty) * ((1 - tx) * h00 + tx * h10) + ty * ((1 - tx) * h01 + tx * h11)
        }

        // Sparse edge fallback: inverse-distance interpolation within two cells.
        var weighted = 0.0
        var weights = 0.0
        for dx in -2...2 {
            for dy in -2...2 {
                let key = SIMD2<Int32>(x0 + Int32(dx), y0 + Int32(dy))
                guard let cell = lookup[key] else { continue }
                let centre = SIMD2<Double>((Double(key.x) + 0.5) * size, (Double(key.y) + 0.5) * size)
                let distance = max(simd_distance(centre, point), size * 0.5)
                let weight = 1 / (distance * distance)
                weighted += Double(cell.height) * weight
                weights += weight
            }
        }
        return weights > 0 ? weighted / weights : nil
    }

    func gradient(at point: SIMD2<Double>) -> SIMD2<Double> {
        gradientIfAvailable(at: point) ?? .zero
    }

    func gradientIfAvailable(at point: SIMD2<Double>) -> SIMD2<Double>? {
        let size = Double(snapshot.cellSize)
        let gx = point.x / size
        let gy = point.y / size
        let x0 = Int32(floor(gx))
        let y0 = Int32(floor(gy))
        let tx = gx - Double(x0)
        let ty = gy - Double(y0)
        let k00 = SIMD2<Int32>(x0, y0)
        let k10 = SIMD2<Int32>(x0 + 1, y0)
        let k01 = SIMD2<Int32>(x0, y0 + 1)
        let k11 = SIMD2<Int32>(x0 + 1, y0 + 1)
        if let g00 = gradientLookup[k00], let g10 = gradientLookup[k10],
           let g01 = gradientLookup[k01], let g11 = gradientLookup[k11] {
            return (1 - ty) * ((1 - tx) * g00 + tx * g10) + ty * ((1 - tx) * g01 + tx * g11)
        }

        var weighted = SIMD2<Double>.zero
        var weights = 0.0
        for dx in -2...2 {
            for dy in -2...2 {
                let key = SIMD2<Int32>(x0 + Int32(dx), y0 + Int32(dy))
                guard let gradient = gradientLookup[key] else { continue }
                let centre = SIMD2<Double>((Double(key.x) + 0.5) * size, (Double(key.y) + 0.5) * size)
                let distance = max(simd_distance(centre, point), size * 0.5)
                let weight = 1 / (distance * distance)
                weighted += gradient * weight
                weights += weight
            }
        }
        return weights > 0 ? weighted / weights : nil
    }

    func gradient(at cell: HeightCell) -> SIMD2<Double> {
        gradientLookup[SIMD2<Int32>(Int32(cell.x), Int32(cell.y))] ?? .zero
    }
}
