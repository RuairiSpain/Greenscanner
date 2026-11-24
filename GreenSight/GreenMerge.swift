import Foundation
import CoreLocation
import simd

// MARK: Polygon raster

/// A polygon rasterised on a regular grid, used for fast overlap scoring.
struct PolygonMask {
    let cellSize: Float
    let originX: Float
    let originZ: Float
    let width: Int
    let height: Int
    private(set) var bits: [Bool]
    private(set) var count = 0

    init(polygon: [SIMD2<Float>], cellSize: Float) {
        self.cellSize = cellSize
        guard let bounds = GreenGeometry.bounds(polygon) else {
            originX = 0; originZ = 0; width = 0; height = 0; bits = []
            return
        }
        originX = floor(bounds.min.x / cellSize) * cellSize
        originZ = floor(bounds.min.y / cellSize) * cellSize
        width = Int(ceil((bounds.max.x - originX) / cellSize)) + 1
        height = Int(ceil((bounds.max.y - originZ) / cellSize)) + 1
        bits = [Bool](repeating: false, count: width * height)
        for j in 0..<height {
            for i in 0..<width {
                let centre = SIMD2<Float>(originX + (Float(i) + 0.5) * cellSize, originZ + (Float(j) + 0.5) * cellSize)
                if GreenGeometry.contains(polygon, point: centre) {
                    bits[j * width + i] = true
                    count += 1
                }
            }
        }
    }

    func contains(_ point: SIMD2<Float>) -> Bool {
        let i = Int(floor((point.x - originX) / cellSize))
        let j = Int(floor((point.y - originZ) / cellSize))
        guard i >= 0, i < width, j >= 0, j < height else { return false }
        return bits[j * width + i]
    }

    /// Centres of mask cells, thinned to roughly `spacing` metres.
    func samplePoints(spacing: Float) -> [SIMD2<Float>] {
        let step = max(1, Int((spacing / cellSize).rounded()))
        var points: [SIMD2<Float>] = []
        for j in stride(from: 0, to: height, by: step) {
            for i in stride(from: 0, to: width, by: step) where bits[j * width + i] {
                points.append(SIMD2<Float>(originX + (Float(i) + 0.5) * cellSize, originZ + (Float(j) + 0.5) * cellSize))
            }
        }
        return points
    }
}

// MARK: Alignment

/// Rigid transform (rotation about the centroids plus a translation) taking one scan's frame to another's.
struct GreenAlignment: Sendable {
    let angle: Float
    let translation: SIMD2<Float>
    let sourceCentroid: SIMD2<Float>
    let targetCentroid: SIMD2<Float>
    /// Intersection over union of the two outlines after alignment, 0...1.
    let overlap: Float

    func apply(_ point: SIMD2<Float>) -> SIMD2<Float> {
        let q = point - sourceCentroid
        let c = cos(angle), s = sin(angle)
        return SIMD2<Float>(c * q.x - s * q.y, s * q.x + c * q.y) + targetCentroid + translation
    }
}

enum GreenAligner {
    static let minimumOverlap: Float = 0.6

    static func centroid(_ polygon: [SIMD2<Float>]) -> SIMD2<Float> {
        var areaSum: Float = 0
        var cx: Float = 0, cz: Float = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let cross = a.x * b.y - b.x * a.y
            areaSum += cross
            cx += (a.x + b.x) * cross
            cz += (a.y + b.y) * cross
        }
        if abs(areaSum) < 1e-6 {
            let sum = polygon.reduce(SIMD2<Float>.zero, +)
            return sum / Float(max(polygon.count, 1))
        }
        return SIMD2<Float>(cx, cz) / (3 * areaSum)
    }

    /// Finds the rotation and translation that best overlay `source`'s outline on `target`'s.
    /// If both scans are north-aligned only a small rotation is searched, otherwise the full circle.
    static func align(source: [SIMD2<Float>], sourceAligned: Bool,
                      target: [SIMD2<Float>], targetAligned: Bool) -> GreenAlignment? {
        let targetMask = PolygonMask(polygon: target, cellSize: 0.25)
        let sourceMask = PolygonMask(polygon: source, cellSize: 0.25)
        guard targetMask.count > 0, sourceMask.count > 0 else { return nil }
        let centreTarget = centroid(target)
        let centreSource = centroid(source)
        let sourcePoints = sourceMask.samplePoints(spacing: 0.5).map { $0 - centreSource }
        let sourceCount = Float(sourcePoints.count)
        let targetCount = Float(targetMask.samplePoints(spacing: 0.5).count)
        guard sourceCount > 0, targetCount > 0 else { return nil }

        func score(angle: Float, shift: SIMD2<Float>) -> Float {
            let c = cos(angle), s = sin(angle)
            var inside: Float = 0
            for q in sourcePoints {
                let p = SIMD2<Float>(c * q.x - s * q.y, s * q.x + c * q.y) + centreTarget + shift
                if targetMask.contains(p) { inside += 1 }
            }
            let union = sourceCount + targetCount - inside
            return union > 0 ? inside / union : 0
        }

        let degrees = Float.pi / 180
        let coarse: [Float]
        if sourceAligned && targetAligned {
            coarse = Array(stride(from: Float(-25), through: 25, by: 5))
        } else {
            coarse = Array(stride(from: Float(0), to: 360, by: 5))
        }
        let ranked = coarse
            .map { (angle: $0, score: score(angle: $0 * degrees, shift: .zero)) }
            .sorted { $0.score > $1.score }
            .prefix(2)

        var best: GreenAlignment?
        var bestScore: Float = -1
        for candidate in ranked {
            for dAngle in stride(from: Float(-4), through: 4, by: 1) {
                let angle = (candidate.angle + dAngle) * degrees
                for tx in stride(from: Float(-2), through: 2, by: 0.25) {
                    for tz in stride(from: Float(-2), through: 2, by: 0.25) {
                        let shift = SIMD2<Float>(tx, tz)
                        let value = score(angle: angle, shift: shift)
                        if value > bestScore {
                            bestScore = value
                            best = GreenAlignment(angle: angle, translation: shift, sourceCentroid: centreSource,
                                                  targetCentroid: centreTarget, overlap: value)
                        }
                    }
                }
            }
        }
        guard let best, best.overlap >= minimumOverlap else { return nil }
        return best
    }
}

// MARK: Outline union

enum GreenOutline {
    /// Union of several outlines on the map grid, returned as one simplified polygon plus its cell set.
    static func union(polygons: [[SIMD2<Float>]], cellSize: Float) -> (outline: [SIMD2<Float>], cells: Set<SIMD2<Int32>>)? {
        let boxes = polygons.compactMap { GreenGeometry.bounds($0) }
        guard let first = boxes.first else { return nil }
        var low = first.min, high = first.max
        for box in boxes { low = simd_min(low, box.min); high = simd_max(high, box.max) }
        let x0 = Int32(floor(low.x / cellSize)), x1 = Int32(floor(high.x / cellSize))
        let z0 = Int32(floor(low.y / cellSize)), z1 = Int32(floor(high.y / cellSize))
        guard x1 >= x0, z1 >= z0 else { return nil }

        var cells = Set<SIMD2<Int32>>()
        for i in x0...x1 {
            for j in z0...z1 {
                let centre = SIMD2<Float>((Float(i) + 0.5) * cellSize, (Float(j) + 0.5) * cellSize)
                if polygons.contains(where: { GreenGeometry.contains($0, point: centre) }) {
                    cells.insert(SIMD2<Int32>(i, j))
                }
            }
        }
        let component = largestComponent(cells)
        guard component.count >= 4 else { return nil }
        let loop = traceOuterLoop(component)
        guard loop.count >= 4 else { return nil }
        let raw = loop.map { SIMD2<Float>(Float($0.x) * cellSize, Float($0.y) * cellSize) }
        let simplified = simplify(raw, tolerance: cellSize * 0.75)
        let outline = (simplified.count >= 4 && !GreenGeometry.selfIntersects(simplified)) ? simplified : raw
        return (outline, component)
    }

    static func largestComponent(_ cells: Set<SIMD2<Int32>>) -> Set<SIMD2<Int32>> {
        var remaining = cells
        var best = Set<SIMD2<Int32>>()
        while let seed = remaining.first {
            var component = Set<SIMD2<Int32>>([seed])
            var stack = [seed]
            remaining.remove(seed)
            while let current = stack.popLast() {
                for offset in [SIMD2<Int32>(1, 0), SIMD2<Int32>(-1, 0), SIMD2<Int32>(0, 1), SIMD2<Int32>(0, -1)] {
                    let next = current &+ offset
                    if remaining.remove(next) != nil {
                        component.insert(next)
                        stack.append(next)
                    }
                }
            }
            if component.count > best.count { best = component }
        }
        return best
    }

    /// Outer boundary of a cell set as grid-corner coordinates, with collinear points removed.
    static func traceOuterLoop(_ cells: Set<SIMD2<Int32>>) -> [SIMD2<Int32>] {
        var edges: [SIMD2<Int32>: [SIMD2<Int32>]] = [:]
        for cell in cells {
            let i = cell.x, j = cell.y
            if !cells.contains(SIMD2<Int32>(i, j - 1)) { edges[SIMD2<Int32>(i, j), default: []].append(SIMD2<Int32>(i + 1, j)) }
            if !cells.contains(SIMD2<Int32>(i + 1, j)) { edges[SIMD2<Int32>(i + 1, j), default: []].append(SIMD2<Int32>(i + 1, j + 1)) }
            if !cells.contains(SIMD2<Int32>(i, j + 1)) { edges[SIMD2<Int32>(i + 1, j + 1), default: []].append(SIMD2<Int32>(i, j + 1)) }
            if !cells.contains(SIMD2<Int32>(i - 1, j)) { edges[SIMD2<Int32>(i, j + 1), default: []].append(SIMD2<Int32>(i, j)) }
        }

        var loops: [[SIMD2<Int32>]] = []
        while let start = edges.first(where: { !$0.value.isEmpty })?.key {
            var loop = [start]
            var current = start
            var guardCount = 0
            while guardCount < 2_000_000 {
                guardCount += 1
                guard var outgoing = edges[current], !outgoing.isEmpty else { break }
                let next = outgoing.removeFirst()
                edges[current] = outgoing
                if next == start { break }
                loop.append(next)
                current = next
            }
            loops.append(loop)
        }

        func signedArea(_ loop: [SIMD2<Int32>]) -> Int {
            var sum = 0
            for index in loop.indices {
                let a = loop[index], b = loop[(index + 1) % loop.count]
                sum += Int(a.x) * Int(b.y) - Int(b.x) * Int(a.y)
            }
            return abs(sum)
        }
        guard let outer = loops.max(by: { signedArea($0) < signedArea($1) }) else { return [] }

        var reduced: [SIMD2<Int32>] = []
        for index in outer.indices {
            let previous = outer[(index + outer.count - 1) % outer.count]
            let current = outer[index]
            let next = outer[(index + 1) % outer.count]
            let cross = (Int(current.x) - Int(previous.x)) * (Int(next.y) - Int(current.y))
                - (Int(current.y) - Int(previous.y)) * (Int(next.x) - Int(current.x))
            if cross != 0 { reduced.append(current) }
        }
        return reduced
    }

    /// Douglas-Peucker simplification of a closed polygon.
    static func simplify(_ points: [SIMD2<Float>], tolerance: Float) -> [SIMD2<Float>] {
        guard points.count > 4 else { return points }
        var far = 0
        var farthest: Float = 0
        for index in 1..<points.count {
            let d = simd_distance(points[0], points[index])
            if d > farthest { farthest = d; far = index }
        }
        guard far > 0 else { return points }
        let first = Array(points[0...far])
        let second = Array(points[far...]) + [points[0]]
        let a = douglasPeucker(first, tolerance)
        let b = douglasPeucker(second, tolerance)
        return Array(a.dropLast()) + Array(b.dropLast())
    }

    private static func douglasPeucker(_ points: [SIMD2<Float>], _ tolerance: Float) -> [SIMD2<Float>] {
        guard points.count > 2, let a = points.first, let b = points.last else { return points }
        var index = 0
        var maxDistance: Float = 0
        for i in 1..<(points.count - 1) {
            let d = distance(points[i], toSegment: a, b)
            if d > maxDistance { maxDistance = d; index = i }
        }
        guard maxDistance > tolerance else { return [a, b] }
        let left = douglasPeucker(Array(points[0...index]), tolerance)
        let right = douglasPeucker(Array(points[index...]), tolerance)
        return Array(left.dropLast()) + right
    }

    private static func distance(_ p: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_dot(ab, ab)
        guard lengthSquared > 1e-12 else { return simd_distance(p, a) }
        let t = (simd_dot(p - a, ab) / lengthSquared).clamped(to: 0...1)
        return simd_distance(p, a + ab * t)
    }
}

// MARK: Merge

struct MergeResult: Sendable {
    let record: GreenMapRecord
    let usedCount: Int
    let skipped: [String]
    /// Median disagreement between scans after alignment and height correction, in millimetres.
    let residualMillimetres: Double?
    /// Lowest outline overlap among the aligned scans, 0...1.
    let minimumOverlap: Double
}

enum MergeError: LocalizedError {
    case tooFewScans
    case noneAligned([String])

    var errorDescription: String? {
        switch self {
        case .tooFewScans:
            return "Select at least two scans of the same hole."
        case .noneAligned(let reasons):
            return "These scans could not be combined. " + reasons.joined(separator: " ")
        }
    }
}

enum GreenMerger {
    static let maximumOriginSeparation: Double = 150
    static let minimumHeightOverlapCells = 20

    private struct Contribution {
        var height: Float
        var weight: Float
        var observations: Int
        var range: Float
    }

    private static func weight(_ cell: MapCell, quality: Double) -> Float {
        let range = max(1, cell.bestRange)
        return Float(max(quality, 0.05)) * Float(min(cell.observations, 20)) / (range * range)
    }

    static func merge(_ records: [GreenMapRecord]) throws -> MergeResult {
        guard records.count >= 2 else { throw MergeError.tooFewScans }
        let ordered = records.sorted { $0.qualityScore > $1.qualityScore }
        let reference = ordered[0]
        let size = reference.cellSize
        let referencePolygon = reference.edgeVector

        var contributions: [SIMD2<Int32>: [Contribution]] = [:]
        var referenceHeights: [SIMD2<Int32>: Float] = [:]
        for cell in reference.cells {
            let key = SIMD2<Int32>(Int32(cell.ix), Int32(cell.iz))
            referenceHeights[key] = cell.height
            contributions[key, default: []].append(Contribution(
                height: cell.height, weight: weight(cell, quality: reference.qualityScore),
                observations: cell.observations, range: cell.bestRange))
        }

        var polygons = [referencePolygon]
        var used = [reference]
        var skipped: [String] = []
        var residuals: [Float] = []
        var lowestOverlap: Float = 1

        for other in ordered.dropFirst() {
            let label = "Scan from \(other.createdAt.formatted(date: .abbreviated, time: .shortened))"
            guard other.cellSize == size else { skipped.append("\(label) uses a different grid size."); continue }
            if let a = other.originLatitude, let b = other.originLongitude,
               let c = reference.originLatitude, let d = reference.originLongitude,
               CLLocation(latitude: a, longitude: b).distance(from: CLLocation(latitude: c, longitude: d)) > maximumOriginSeparation {
                skipped.append("\(label) was taken more than \(Int(maximumOriginSeparation)) m away.")
                continue
            }
            guard let alignment = GreenAligner.align(source: other.edgeVector, sourceAligned: other.headingAligned,
                                                     target: referencePolygon, targetAligned: reference.headingAligned) else {
                skipped.append("\(label) has an outline that does not match the best scan.")
                continue
            }

            // Re-bin the other scan's cells onto the reference grid.
            struct Bin { var sumW: Float = 0; var sumWH: Float = 0; var sumX: Float = 0; var sumZ: Float = 0
                         var obs = 0; var range = Float.greatestFiniteMagnitude }
            var bins: [SIMD2<Int32>: Bin] = [:]
            for cell in other.cells {
                let centre = SIMD2<Float>((Float(cell.ix) + 0.5) * size, (Float(cell.iz) + 0.5) * size)
                let p = alignment.apply(centre)
                let key = SIMD2<Int32>(Int32(floor(p.x / size)), Int32(floor(p.y / size)))
                let w = weight(cell, quality: other.qualityScore)
                var bin = bins[key] ?? Bin()
                bin.sumW += w; bin.sumWH += w * cell.height
                bin.sumX += w * p.x; bin.sumZ += w * p.y
                bin.obs += cell.observations
                bin.range = min(bin.range, cell.bestRange)
                bins[key] = bin
            }

            // Fit the height difference over the shared area: an offset, plus a tilt when well constrained.
            struct Sample { let x: Double; let z: Double; let d: Double }
            var samples: [Sample] = []
            for (key, bin) in bins where bin.sumW > 0 {
                guard let reference = referenceHeights[key] else { continue }
                samples.append(Sample(x: Double(bin.sumX / bin.sumW), z: Double(bin.sumZ / bin.sumW),
                                      d: Double(reference - bin.sumWH / bin.sumW)))
            }
            guard samples.count >= minimumHeightOverlapCells else {
                skipped.append("\(label) shares too little scanned area to align heights.")
                continue
            }
            let medianDifference = Double(median(samples.map { Float($0.d) }))
            let inliers = samples.filter { abs($0.d - medianDifference) < 0.05 }
            var offset = medianDifference
            var tiltX = 0.0, tiltZ = 0.0
            var centreX = 0.0, centreZ = 0.0
            if inliers.count >= 40 {
                let mx = inliers.map(\.x).reduce(0, +) / Double(inliers.count)
                let mz = inliers.map(\.z).reduce(0, +) / Double(inliers.count)
                let spanX = (inliers.map(\.x).max() ?? 0) - (inliers.map(\.x).min() ?? 0)
                let spanZ = (inliers.map(\.z).max() ?? 0) - (inliers.map(\.z).min() ?? 0)
                if spanX > 1.5, spanZ > 1.5 {
                    var n = simd_double3x3(diagonal: SIMD3<Double>(repeating: 0))
                    var rhs = SIMD3<Double>(0, 0, 0)
                    for s in inliers {
                        let v = SIMD3<Double>(1, s.x - mx, s.z - mz)
                        n += simd_double3x3(columns: (v * v.x, v * v.y, v * v.z))
                        rhs += v * s.d
                    }
                    if abs(n.determinant) > 1e-9 {
                        let solution = n.inverse * rhs
                        if abs(solution.y) <= 0.03, abs(solution.z) <= 0.03 {
                            offset = solution.x; tiltX = solution.y; tiltZ = solution.z
                            centreX = mx; centreZ = mz
                        }
                    }
                }
            }

            var afterCorrection: [Float] = []
            for (key, bin) in bins where bin.sumW > 0 {
                let x = Double(bin.sumX / bin.sumW), z = Double(bin.sumZ / bin.sumW)
                let corrected = Float(Double(bin.sumWH / bin.sumW) + offset + tiltX * (x - centreX) + tiltZ * (z - centreZ))
                contributions[key, default: []].append(Contribution(
                    height: corrected, weight: bin.sumW, observations: bin.obs, range: bin.range))
                if let reference = referenceHeights[key] { afterCorrection.append(abs(reference - corrected)) }
            }
            residuals.append(median(afterCorrection))
            polygons.append(other.edgeVector.map { alignment.apply($0) })
            used.append(other)
            lowestOverlap = min(lowestOverlap, alignment.overlap)
        }

        guard used.count >= 2 else { throw MergeError.noneAligned(skipped) }
        guard let union = GreenOutline.union(polygons: polygons, cellSize: size) else {
            throw MergeError.noneAligned(["The combined outline is invalid."])
        }

        var cells: [MapCell] = []
        for (key, list) in contributions where union.cells.contains(key) {
            var chosen = list
            if list.count >= 3 {
                let centre = weightedMedian(list.map { ($0.height, $0.weight) })
                let filtered = list.filter { abs($0.height - centre) <= 0.04 }
                if !filtered.isEmpty { chosen = filtered }
            }
            let totalWeight = chosen.reduce(Float(0)) { $0 + $1.weight }
            guard totalWeight > 0 else { continue }
            let height = chosen.reduce(Float(0)) { $0 + $1.height * $1.weight } / totalWeight
            cells.append(MapCell(ix: Int(key.x), iz: Int(key.y), height: height,
                                 observations: min(200, chosen.reduce(0) { $0 + $1.observations }),
                                 bestRange: chosen.map(\.range).min() ?? 0))
        }
        cells.sort { ($0.iz, $0.ix) < ($1.iz, $1.ix) }

        let coverage = Double(cells.count) / Double(max(union.cells.count, 1))
        // Quality per unit of coverage for each source, averaged by cells contributed, then rescaled to the merged coverage.
        var weighted = 0.0, totalCells = 0.0
        for source in used {
            let perCoverage = min(1, source.qualityScore / max(source.coverage, 0.05))
            weighted += perCoverage * Double(source.cells.count)
            totalCells += Double(source.cells.count)
        }
        let quality = (coverage * (totalCells > 0 ? weighted / totalCells : 0)).clamped(to: 0...1)
        let residualMM = residuals.isEmpty ? nil : Double(residuals.max() ?? 0) * 1000

        let record = GreenMapRecord(
            id: UUID(), courseName: reference.courseName, holeNumber: reference.holeNumber, createdAt: Date(),
            cellSize: size, edge: union.outline.map { EdgePoint(x: $0.x, z: $0.y) }, cells: cells,
            coverage: coverage, qualityScore: quality, driftMillimetres: residualMM,
            trackingLossCount: used.reduce(0) { $0 + $1.trackingLossCount },
            isPartial: coverage < 0.85, headingAligned: reference.headingAligned,
            originLatitude: reference.originLatitude, originLongitude: reference.originLongitude,
            sourceIDs: used.map(\.id), sourceScanCount: used.count)
        return MergeResult(record: record, usedCount: used.count, skipped: skipped,
                           residualMillimetres: residualMM, minimumOverlap: Double(lowestOverlap))
    }

    private static func weightedMedian(_ values: [(Float, Float)]) -> Float {
        let sorted = values.sorted { $0.0 < $1.0 }
        let half = sorted.reduce(Float(0)) { $0 + $1.1 } / 2
        var running: Float = 0
        for (value, weight) in sorted {
            running += weight
            if running >= half { return value }
        }
        return sorted.last?.0 ?? 0
    }
}
