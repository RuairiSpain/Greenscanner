import Foundation
import simd

// MARK: Fringe detection

struct EdgeSuggestion: Sendable {
    let polygon: [SIMD2<Float>]
    /// Share of sampled edge positions (0...1) where a clear change in surface texture was found.
    let detectedFraction: Double
    let medianShiftMetres: Float
    let maxShiftMetres: Float

    var isUseful: Bool { detectedFraction >= EdgeRefiner.minimumDetectedFraction && maxShiftMetres >= 0.1 }
}

/// Looks for the fringe in the scan data and suggests an outline that follows it.
///
/// Fringe grass is longer than green grass, so depth readings there are noisier from frame to frame. Along
/// lines across the walked outline, the detector finds where that roughness steps up and moves the outline there.
/// It uses cells inside the outline and the strip just outside it, so it can move the edge by up to
/// `maximumShift` metres either way. Surface height is not used: slope across a green edge hides small steps.
enum EdgeRefiner {
    static let spacing: Float = 1.0
    static let halfWidth: Float = 1.0
    static let step: Float = 0.2
    static let maximumShift: Float = 0.8
    /// t-statistic of the roughness step needed to accept a detection.
    static let minimumEffect = 3.0
    static let minimumDetectedFraction = 0.4

    private struct Sample {
        let position: SIMD2<Float>
        let direction: SIMD2<Float>      // unit outward direction used for the profile
        let moveScale: Float             // >1 at sharp corners so a moved edge stays parallel
    }

    static func signedArea(_ polygon: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    static func suggest(edge: [SIMD2<Float>], cells: [MapCell], outerCells: [MapCell], cellSize: Float) -> EdgeSuggestion? {
        guard edge.count >= 3 else { return nil }
        let signed = signedArea(edge)
        guard abs(signed) > 1 else { return nil }
        var lookup: [SIMD2<Int32>: Float] = [:]
        for cell in cells + outerCells {
            if let noise = cell.noise { lookup[SIMD2<Int32>(Int32(cell.ix), Int32(cell.iz))] = noise }
        }
        guard lookup.count >= 30 else { return nil }

        let samples = makeSamples(edge, counterClockwise: signed > 0)
        guard samples.count >= 4 else { return nil }

        let offsets = stride(from: -halfWidth, through: halfWidth + 0.001, by: step).map { $0 }
        var raw: [Float?] = samples.map { sample in
            let profile: [Float?] = offsets.map { t in
                let q = sample.position + sample.direction * t
                return lookup[SIMD2<Int32>(Int32(floor(q.x / cellSize)), Int32(floor(q.y / cellSize)))]
            }
            guard let split = bestRoughnessStep(profile) else { return nil }
            let shift = (offsets[split - 1] + offsets[split]) / 2
            return abs(shift) <= maximumShift ? shift : nil
        }

        // A real fringe runs continuously: keep a shift only where neighbours agree, using their median.
        func smoothed(window: Int) -> [Float?] {
            raw.indices.map { i in
                var neighbours: [Float] = []
                for offset in -window...window {
                    if let value = raw[(i + offset + raw.count) % raw.count] { neighbours.append(value) }
                }
                return neighbours.count >= max(3, window) ? median(neighbours) : nil
            }
        }
        var shifts = smoothed(window: 2)
        for attempt in 0..<2 {
            let detected = shifts.compactMap { $0 }
            let fraction = Double(detected.count) / Double(shifts.count)
            let moved = zip(samples, shifts).map { sample, shift in
                sample.position + sample.direction * ((shift ?? 0) * sample.moveScale)
            }
            let simplified = GreenOutline.simplify(removeDuplicates(moved), tolerance: 0.15)
            let areaRatio = abs(signedArea(simplified)) / abs(signed)
            if simplified.count >= 3, !GreenGeometry.selfIntersects(simplified), areaRatio > 0.5, areaRatio < 2 {
                let magnitudes = detected.map(abs)
                return EdgeSuggestion(polygon: simplified, detectedFraction: fraction,
                                      medianShiftMetres: magnitudes.isEmpty ? 0 : median(magnitudes),
                                      maxShiftMetres: magnitudes.max() ?? 0)
            }
            if attempt == 0 { shifts = smoothed(window: 4) }
        }
        return EdgeSuggestion(polygon: edge, detectedFraction: 0, medianShiftMetres: 0, maxShiftMetres: 0)
    }

    private static func makeSamples(_ edge: [SIMD2<Float>], counterClockwise: Bool) -> [Sample] {
        func normal(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
            let d = simd_normalize(b - a)
            return counterClockwise ? SIMD2<Float>(d.y, -d.x) : SIMD2<Float>(-d.y, d.x)
        }
        var samples: [Sample] = []
        for index in edge.indices {
            let previous = edge[(index + edge.count - 1) % edge.count]
            let a = edge[index], b = edge[(index + 1) % edge.count]
            guard simd_distance(a, b) > 0.01, simd_distance(previous, a) > 0.01 else { continue }
            let current = normal(a, b)
            let incoming = normal(previous, a)
            let blended = incoming + current
            let direction = simd_length(blended) > 1e-4 ? simd_normalize(blended) : current
            samples.append(Sample(position: a, direction: direction,
                                  moveScale: 1 / max(simd_dot(direction, current), 0.55)))
            let length = simd_distance(a, b)
            var t = spacing
            while t < length - spacing * 0.5 {
                samples.append(Sample(position: a + (b - a) * (t / length), direction: current, moveScale: 1))
                t += spacing
            }
        }
        return samples
    }

    /// Index k where values from k onward are clearly rougher than before it, or nil.
    private static func bestRoughnessStep(_ values: [Float?]) -> Int? {
        var best: (index: Int, effect: Double)?
        guard values.count >= 6 else { return nil }
        for k in 3...(values.count - 3) {
            let left = values[..<k].compactMap { $0 }
            let right = values[k...].compactMap { $0 }
            guard left.count >= 3, right.count >= 3 else { continue }
            let meanLeft = left.reduce(0, +) / Float(left.count)
            let meanRight = right.reduce(0, +) / Float(right.count)
            let ss = left.reduce(Float(0)) { $0 + ($1 - meanLeft) * ($1 - meanLeft) }
                + right.reduce(Float(0)) { $0 + ($1 - meanRight) * ($1 - meanRight) }
            let degrees = Float(left.count + right.count - 2)
            let sigma = max((ss / max(degrees, 1)).squareRoot(), 0.0005)
            let effect = Double((meanRight - meanLeft) / (sigma * (1 / Float(left.count) + 1 / Float(right.count)).squareRoot()))
            if effect > (best?.effect ?? minimumEffect) { best = (k, effect) }
        }
        return best?.index
    }

    private static func removeDuplicates(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var output: [SIMD2<Float>] = []
        for p in points where output.last.map({ simd_distance($0, p) > 0.05 }) ?? true { output.append(p) }
        if output.count > 1, let first = output.first, let last = output.last, simd_distance(first, last) <= 0.05 { output.removeLast() }
        return output
    }
}

// MARK: Edge edits

enum GreenEdit {
    static func validate(_ polygon: [SIMD2<Float>]) -> String? {
        guard polygon.count >= 3 else { return "An outline needs at least 3 points." }
        guard GreenGeometry.area(polygon) >= 4 else { return "The outline is too small to be a green." }
        guard !GreenGeometry.selfIntersects(polygon) else { return "The outline crosses itself." }
        return nil
    }

    /// Height of the scanned surface at each outline point, from nearby cells; nil where nothing was scanned.
    static func edgeHeights(polygon: [SIMD2<Float>], pool: [MapCell], cellSize: Float) -> [Float?] {
        var lookup: [SIMD2<Int32>: Float] = [:]
        for cell in pool { lookup[SIMD2<Int32>(Int32(cell.ix), Int32(cell.iz))] = cell.height }
        return polygon.map { point in
            let cx = Int32(floor(point.x / cellSize)), cz = Int32(floor(point.y / cellSize))
            var weighted: Float = 0, total: Float = 0
            for dx in Int32(-3)...3 {
                for dz in Int32(-3)...3 {
                    guard let height = lookup[SIMD2<Int32>(cx + dx, cz + dz)] else { continue }
                    let centre = SIMD2<Float>((Float(cx + dx) + 0.5) * cellSize, (Float(cz + dz) + 0.5) * cellSize)
                    let w = 1 / (simd_distance_squared(centre, point) + 0.01)
                    weighted += height * w
                    total += w
                }
            }
            return total > 0 ? weighted / total : nil
        }
    }

    /// Number of grid cells whose centre lies inside the polygon.
    static func cellCount(inside polygon: [SIMD2<Float>], cellSize: Float) -> Int {
        guard let bounds = GreenGeometry.bounds(polygon) else { return 0 }
        var count = 0
        for ix in Int32(floor(bounds.min.x / cellSize))...Int32(floor(bounds.max.x / cellSize)) {
            for iz in Int32(floor(bounds.min.y / cellSize))...Int32(floor(bounds.max.y / cellSize)) {
                let centre = SIMD2<Float>((Float(ix) + 0.5) * cellSize, (Float(iz) + 0.5) * cellSize)
                if GreenGeometry.contains(polygon, point: centre) { count += 1 }
            }
        }
        return count
    }

    /// Re-cuts a saved green to a new outline. Cells are never discarded: those outside the new outline move to
    /// the outer strip, and cells in the strip that the new outline covers move back in, so edits can be undone.
    static func apply(to record: GreenMapRecord, polygon: [SIMD2<Float>], source: String) -> GreenMapRecord? {
        guard validate(polygon) == nil else { return nil }
        let size = record.cellSize
        let pool = record.cells + (record.outerCells ?? [])
        var inside: [MapCell] = []
        var outer: [MapCell] = []
        for cell in pool {
            let centre = SIMD2<Float>((Float(cell.ix) + 0.5) * size, (Float(cell.iz) + 0.5) * size)
            if GreenGeometry.contains(polygon, point: centre) {
                inside.append(cell)
            } else if GreenGeometry.distance(from: centre, toBoundaryOf: polygon) <= GreenMapAccumulator.bandWidth {
                outer.append(cell)
            }
        }
        let total = max(cellCount(inside: polygon, cellSize: size), 1)
        let coverage = min(1, Double(inside.count) / Double(total))
        let qualityPerCoverage = record.qualityScore / max(record.coverage, 0.05)
        let heights = edgeHeights(polygon: polygon, pool: pool, cellSize: size)

        var updated = record
        updated.edge = polygon.enumerated().map { EdgePoint(x: $0.element.x, z: $0.element.y, y: heights[$0.offset]) }
        updated.cells = inside
        updated.outerCells = outer
        updated.coverage = coverage
        updated.qualityScore = min(1, max(0, coverage * qualityPerCoverage))
        updated.isPartial = coverage < 0.85
        updated.edgeSource = source
        updated.zoneCount = nil
        updated.unlinkedZones = nil
        return updated
    }
}
