import Foundation
import simd

enum ZoneState: String, Sendable {
    case notStarted, inProgress, complete
}

struct ZoneStatus: Sendable, Equatable {
    let index: Int
    let centre: SIMD2<Float>
    let cellCount: Int
    let coveredCount: Int
    let state: ZoneState
    /// True when this zone's heights are tied to the rest of the scan through cells seen from both sides.
    let linked: Bool
    var coverage: Double { Double(coveredCount) / Double(max(cellCount, 1)) }
}

/// Accumulates depth samples inside a green outline into a fixed grid.
///
/// The green is split into zones of roughly 6 m. Observations are grouped into "epochs": a new epoch starts
/// when the camera moves into another zone, after `maxEpochDuration` seconds, or after a tracking
/// discontinuity. Cells seen in more than one epoch tie the epochs together, and a least-squares solve
/// estimates a vertical offset per epoch so tracking drift between passes is removed.
final class GreenMapAccumulator: @unchecked Sendable {
    struct Entry: Codable {
        var epoch: Int32
        var sumWeight: Float
        var sumWeightedHeight: Float
        var sumWeightedSquares: Double
        var count: Int32
    }

    struct Cell {
        var entries: [Entry]
        var count: Int
        var minRange: Float
    }

    struct Summary: Sendable {
        /// Covered cells by quality: observed close and steadily (good), observed from beyond `goodRange` (weak),
        /// or with frame-to-frame height noise above `noisyThreshold` (noisy, needs a slower re-scan).
        let good: Int
        let weak: Int
        let noisy: Int
        let total: Int
        /// Median spread of a cell's height between passes before correction, in millimetres.
        let driftMillimetres: Double?
        /// The same spread after the epoch offsets are applied.
        let residualMillimetres: Double?
        let maxCorrectionMillimetres: Double?
        /// Largest tilt correction applied to any pass, as percent grade.
        let maxTiltPercent: Double?
        /// Height difference where the walk returned to ground it covered in its first pass (needs a pass index
        /// of 2 or more): before and after correction, in millimetres. Nil until the walk has looped back.
        let loopClosureMillimetres: Double?
        let loopClosureResidualMillimetres: Double?
        /// Where scanning began, in map-local metres.
        let startPoint: SIMD2<Float>?
        /// True when the newest pass shares enough cells with the rest of the scan to be corrected.
        let latestEpochLinked: Bool
        let epochCount: Int
        let zones: [ZoneStatus]
        var coverage: Double { Double(good + weak + noisy) / Double(max(total, 1)) }
        var goodShare: Double { good + weak + noisy == 0 ? 0 : Double(good) / Double(good + weak + noisy) }
        var unlinkedZones: Int { zones.filter { $0.state != .notStarted && !$0.linked }.count }
    }

    static let cellSize: Float = 0.2
    /// Observations from farther than this are flagged as weak (amber).
    static let goodRange: Float = 2.5
    /// Width of the strip outside the outline whose cells are kept.
    static let bandWidth: Float = 1.0
    /// Frame-to-frame height standard deviation above this marks a cell as noisy.
    static let noisyThreshold: Float = 0.008
    static let minimumObservations = 3
    static let zoneAreaSquareMetres: Float = 36
    static let minimumZoneCells = 15
    static let maxEpochDuration: Double = 40
    static let maxEpochs = 80
    static let zoneCompletion = 0.9
    /// Epochs are linked when they share at least this many cells.
    static let minimumSharedCells = 8
    /// Penalty on per-pass tilt, in the solver's weight units (about a 1% grade prior).
    static let tiltPrior = 0.5
    static let maximumTilt: Float = 0.03

    private let lock = NSLock()
    private var scanID: UUID?
    private var polygon: [SIMD2<Float>] = []
    private var origin = SIMD3<Float>.zero
    private var cells: [SIMD2<Int32>: Cell] = [:]
    private var insideCache: [SIMD2<Int32>: Bool] = [:]
    /// Cells just outside the outline, kept so the edge can be refined or moved later. Not part of coverage.
    private var bandCells: [SIMD2<Int32>: Cell] = [:]
    private var bandCache: [SIMD2<Int32>: Bool] = [:]
    private var totalInside = 0

    private var zoneOfCell: [SIMD2<Int32>: Int] = [:]
    private var zoneCentres: [SIMD2<Float>] = []
    private var zoneCellCounts: [Int] = []

    private var epochZones: [Int] = []
    private var epochStart: Double = 0
    private var currentZone = -1
    private var discontinuity = false

    private var dirty = false
    /// Per pass: vertical offset (m) and tilt (m per m) in x and z, about `planeCentre`.
    private var planes: [SIMD3<Float>] = []
    private var planeCentre = SIMD2<Float>.zero
    private var epochLinked: [Bool] = []
    private var epochStartTimes: [Double] = []
    private var startPoint: SIMD2<Float>?
    private var rawDrift: Double?
    private var residualDrift: Double?
    private var maxCorrection: Double?
    private var maxTilt: Double?
    private var loopRaw: Double?
    private var loopResidual: Double?

    // MARK: Configuration

    func configure(polygon: [SIMD2<Float>], origin: SIMD3<Float>, scanID: UUID) {
        lock.lock(); defer { lock.unlock() }
        self.polygon = polygon
        self.origin = origin
        self.scanID = scanID
        cells.removeAll(keepingCapacity: true)
        insideCache.removeAll(keepingCapacity: true)
        bandCells.removeAll(keepingCapacity: true)
        bandCache.removeAll(keepingCapacity: true)
        zoneOfCell.removeAll()
        zoneCentres = []
        zoneCellCounts = []
        epochZones = []
        epochStart = 0
        currentZone = -1
        discontinuity = false
        planes = []
        epochLinked = []
        epochStartTimes = []
        startPoint = nil
        rawDrift = nil; residualDrift = nil; maxCorrection = nil
        maxTilt = nil; loopRaw = nil; loopResidual = nil
        if let bounds = GreenGeometry.bounds(polygon) { planeCentre = (bounds.min + bounds.max) / 2 }
        dirty = false
        totalInside = 0
        guard let bounds = GreenGeometry.bounds(polygon) else { return }
        let size = Self.cellSize
        let x0 = Int32(floor(bounds.min.x / size)), x1 = Int32(floor(bounds.max.x / size))
        let z0 = Int32(floor(bounds.min.y / size)), z1 = Int32(floor(bounds.max.y / size))
        guard x1 >= x0, z1 >= z0 else { return }
        var keys: [SIMD2<Int32>] = []
        for ix in x0...x1 {
            for iz in z0...z1 {
                let key = SIMD2<Int32>(ix, iz)
                if isInside(key) { keys.append(key); totalInside += 1 }
            }
        }
        buildZones(keys: keys)
    }

    private func isInside(_ key: SIMD2<Int32>) -> Bool {
        if let cached = insideCache[key] { return cached }
        let size = Self.cellSize
        let centre = SIMD2<Float>((Float(key.x) + 0.5) * size, (Float(key.y) + 0.5) * size)
        let inside = GreenGeometry.contains(polygon, point: centre)
        insideCache[key] = inside
        return inside
    }

    private func isBand(_ key: SIMD2<Int32>) -> Bool {
        if let cached = bandCache[key] { return cached }
        let inBand = !isInside(key)
            && GreenGeometry.distance(from: centre(of: key), toBoundaryOf: polygon) <= Self.bandWidth
        bandCache[key] = inBand
        return inBand
    }

    private func buildZones(keys: [SIMD2<Int32>]) {
        guard !keys.isEmpty else { return }
        let size = Self.cellSize
        let points = keys.map { SIMD2<Float>((Float($0.x) + 0.5) * size, (Float($0.y) + 0.5) * size) }
        let area = Float(keys.count) * size * size
        let k = max(1, min(24, Int((area / Self.zoneAreaSquareMetres).rounded())))
        var (assignment, centres) = Self.partition(points: points, clusters: k)

        // Fold tiny fragments into the nearest larger zone, then renumber densely.
        var counts = [Int](repeating: 0, count: centres.count)
        for a in assignment { counts[a] += 1 }
        let large = counts.indices.filter { counts[$0] >= Self.minimumZoneCells }
        if !large.isEmpty, large.count < centres.count {
            for (i, a) in assignment.enumerated() where counts[a] < Self.minimumZoneCells {
                assignment[i] = large.min { simd_distance_squared(points[i], centres[$0]) < simd_distance_squared(points[i], centres[$1]) } ?? a
            }
        }
        var remap: [Int: Int] = [:]
        for a in assignment where remap[a] == nil { remap[a] = remap.count }
        var sums = [SIMD2<Float>](repeating: .zero, count: remap.count)
        var finalCounts = [Int](repeating: 0, count: remap.count)
        for (i, a) in assignment.enumerated() {
            let z = remap[a] ?? 0
            zoneOfCell[keys[i]] = z
            sums[z] += points[i]
            finalCounts[z] += 1
        }
        zoneCentres = sums.enumerated().map { $0.element / Float(max(finalCounts[$0.offset], 1)) }
        zoneCellCounts = finalCounts
        centres = zoneCentres
    }

    /// Deterministic k-means (farthest-point seeding, then Lloyd iterations) for compact, contiguous zones.
    static func partition(points: [SIMD2<Float>], clusters: Int) -> (assignment: [Int], centres: [SIMD2<Float>]) {
        guard !points.isEmpty else { return ([], []) }
        let k = max(1, min(clusters, points.count))
        let mean = points.reduce(SIMD2<Float>.zero, +) / Float(points.count)
        var first = points[0]
        var bestDistance: Float = -1
        for p in points {
            let d = simd_distance_squared(p, mean)
            if d > bestDistance { bestDistance = d; first = p }
        }
        var centres = [first]
        var nearest = points.map { simd_distance_squared($0, first) }
        while centres.count < k {
            var index = 0
            var farthest: Float = -1
            for i in points.indices where nearest[i] > farthest { farthest = nearest[i]; index = i }
            let centre = points[index]
            centres.append(centre)
            for i in points.indices { nearest[i] = min(nearest[i], simd_distance_squared(points[i], centre)) }
        }

        var assignment = [Int](repeating: 0, count: points.count)
        func assign() {
            for (i, p) in points.enumerated() {
                var best = 0
                var bestD = Float.infinity
                for (j, c) in centres.enumerated() {
                    let d = simd_distance_squared(p, c)
                    if d < bestD { bestD = d; best = j }
                }
                assignment[i] = best
            }
        }
        for _ in 0..<8 {
            assign()
            var sums = [SIMD2<Float>](repeating: .zero, count: k)
            var counts = [Int](repeating: 0, count: k)
            for (i, a) in assignment.enumerated() { sums[a] += points[i]; counts[a] += 1 }
            for j in 0..<k where counts[j] > 0 { centres[j] = sums[j] / Float(counts[j]) }
        }
        assign()
        return (assignment, centres)
    }

    // MARK: Persistence

    /// Everything needed to continue a scan after the app restarts. Zones are rebuilt from the outline.
    struct Snapshot: Codable, Sendable {
        struct CellState: Codable, Sendable {
            let ix: Int32
            let iz: Int32
            let entries: [Entry]
            let count: Int
            let minRange: Float
        }
        let polygon: [SIMD2<Float>]
        let origin: SIMD3<Float>
        let cells: [CellState]
        let epochZones: [Int]
        let currentZone: Int
        var startPoint: SIMD2<Float>? = nil
        var bandCells: [CellState]? = nil
    }

    func snapshot() -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard polygon.count >= 3 else { return nil }
        let states = cells.map { key, cell in
            Snapshot.CellState(ix: key.x, iz: key.y, entries: cell.entries, count: cell.count, minRange: cell.minRange)
        }
        let bandStates = bandCells.map { key, cell in
            Snapshot.CellState(ix: key.x, iz: key.y, entries: cell.entries, count: cell.count, minRange: cell.minRange)
        }
        return Snapshot(polygon: polygon, origin: origin, cells: states, epochZones: epochZones,
                        currentZone: currentZone, startPoint: startPoint, bandCells: bandStates)
    }

    /// Restores a saved scan. The next observations start a new epoch, so the drift solver ties them to
    /// the restored data through the cells they share.
    func restore(_ snapshot: Snapshot, scanID: UUID) {
        configure(polygon: snapshot.polygon, origin: snapshot.origin, scanID: scanID)
        lock.lock(); defer { lock.unlock() }
        for state in snapshot.cells {
            cells[SIMD2<Int32>(state.ix, state.iz)] = Cell(entries: state.entries, count: state.count, minRange: state.minRange)
        }
        for state in snapshot.bandCells ?? [] {
            bandCells[SIMD2<Int32>(state.ix, state.iz)] = Cell(entries: state.entries, count: state.count, minRange: state.minRange)
        }
        epochZones = snapshot.epochZones
        epochStartTimes = [Double](repeating: 0, count: snapshot.epochZones.count)
        startPoint = snapshot.startPoint
        currentZone = snapshot.currentZone
        discontinuity = true
        dirty = true
    }

    // MARK: Epochs

    /// Call when tracking was lost or the session resumed: the next data starts a new epoch.
    func markDiscontinuity() {
        lock.lock(); defer { lock.unlock() }
        discontinuity = true
    }

    private func epochIndex(forCamera camera: SIMD2<Float>, timestamp: Double) -> Int32 {
        var zone = max(currentZone, 0)
        if zoneCentres.count > 1 {
            var best = 0
            var bestDistance = Float.infinity
            for (index, centre) in zoneCentres.enumerated() {
                let d = simd_distance(camera, centre)
                if d < bestDistance { bestDistance = d; best = index }
            }
            if currentZone < 0 {
                zone = best
            } else if best != currentZone, bestDistance + 1.0 < simd_distance(camera, zoneCentres[currentZone]) {
                zone = best
            }
        } else {
            zone = 0
        }
        let needNew = epochZones.isEmpty || zone != currentZone || discontinuity
            || timestamp - epochStart > Self.maxEpochDuration
        if needNew {
            if epochZones.count < Self.maxEpochs {
                if epochZones.isEmpty { startPoint = camera }
                epochZones.append(zone)
                epochStartTimes.append(timestamp)
                epochStart = timestamp
            }
            discontinuity = false
        }
        currentZone = zone
        return Int32(max(epochZones.count - 1, 0))
    }

    private func centre(of key: SIMD2<Int32>) -> SIMD2<Float> {
        SIMD2<Float>((Float(key.x) + 0.5) * Self.cellSize, (Float(key.y) + 0.5) * Self.cellSize)
    }

    /// Height correction for a pass at a map-local position: offset plus tilt about the green's centre.
    private func correction(epoch: Int32, at position: SIMD2<Float>) -> Float {
        let index = Int(epoch)
        guard index < planes.count else { return 0 }
        let plane = planes[index]
        return plane.x + plane.y * (position.x - planeCentre.x) + plane.z * (position.y - planeCentre.y)
    }

    private func correctedMean(_ cell: Cell, key: SIMD2<Int32>) -> Float {
        let position = centre(of: key)
        var weight: Float = 0
        var weighted: Float = 0
        for entry in cell.entries {
            weight += entry.sumWeight
            weighted += entry.sumWeightedHeight + entry.sumWeight * correction(epoch: entry.epoch, at: position)
        }
        return weighted / max(weight, 0.001)
    }

    /// Frame-to-frame height standard deviation within passes, in metres. Nil until a cell has enough frames.
    private func noise(of cell: Cell) -> Float? {
        guard cell.count >= Self.minimumObservations else { return nil }
        var within = 0.0
        var weight = 0.0
        for entry in cell.entries {
            let w = Double(entry.sumWeight)
            guard w > 0 else { continue }
            let mean = Double(entry.sumWeightedHeight) / w
            within += max(0, entry.sumWeightedSquares - w * mean * mean)
            weight += w
        }
        guard weight > 0 else { return nil }
        return Float((within / weight).squareRoot())
    }

    private enum Quality { case good, weak, noisy }

    private func quality(of cell: Cell) -> Quality {
        if let noise = noise(of: cell), noise > Self.noisyThreshold { return .noisy }
        return cell.minRange <= Self.goodRange ? .good : .weak
    }

    // MARK: Ingest

    func ingest(_ samples: [WorldSample], camera: SIMD3<Float>, timestamp: Double, scanID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard scanID == self.scanID, polygon.count >= 3 else { return }
        let size = Self.cellSize

        var bins: [SIMD2<Int32>: (heights: [Float], weight: Float)] = [:]
        for sample in samples {
            let x = sample.position.x - origin.x
            let z = sample.position.z - origin.z
            let key = SIMD2<Int32>(Int32(floor(x / size)), Int32(floor(z / size)))
            guard isInside(key) || isBand(key) else { continue }
            var bin = bins[key] ?? ([], 0)
            bin.heights.append(sample.position.y - origin.y)
            bin.weight += sample.weight
            bins[key] = bin
        }
        guard bins.contains(where: { $0.value.heights.count >= 3 }) else { return }

        let cameraLocal = camera - origin
        let epoch = epochIndex(forCamera: SIMD2<Float>(cameraLocal.x, cameraLocal.z), timestamp: timestamp)

        for (key, bin) in bins {
            guard bin.heights.count >= 3 else { continue }
            let height = median(bin.heights)
            let weight = min(3, bin.weight / Float(bin.heights.count))
            let centreX = (Float(key.x) + 0.5) * size
            let centreZ = (Float(key.y) + 0.5) * size
            let range = simd_length(SIMD3<Float>(cameraLocal.x - centreX, cameraLocal.y - height, cameraLocal.z - centreZ))

            let inside = isInside(key)
            var cell = (inside ? cells[key] : bandCells[key]) ?? Cell(entries: [], count: 0, minRange: .greatestFiniteMagnitude)
            if cell.count >= Self.minimumObservations,
               abs(height + correction(epoch: epoch, at: SIMD2<Float>(centreX, centreZ)) - correctedMean(cell, key: key)) > 0.08 { continue }

            if let index = cell.entries.firstIndex(where: { $0.epoch == epoch }) {
                cell.entries[index].sumWeight += weight
                cell.entries[index].sumWeightedHeight += height * weight
                cell.entries[index].sumWeightedSquares += Double(weight) * Double(height) * Double(height)
                cell.entries[index].count += 1
            } else {
                cell.entries.append(Entry(epoch: epoch, sumWeight: weight, sumWeightedHeight: height * weight,
                                          sumWeightedSquares: Double(weight) * Double(height) * Double(height), count: 1))
            }
            cell.count += 1
            cell.minRange = min(cell.minRange, range)
            if inside { cells[key] = cell } else { bandCells[key] = cell }
        }
        dirty = true
    }

    // MARK: Height correction

    private func refreshIfNeeded() {
        guard dirty else { return }
        dirty = false
        let n = epochZones.count
        guard n > 0 else { planes = []; epochLinked = []; return }

        // Unknowns per pass: vertical offset and tilt in x and z (3 each). Eliminating each cell's true height
        // leaves a weighted Laplacian over the passes that observed it.
        let m = 3 * n
        var matrix = [Double](repeating: 0, count: m * m)
        var rhs = [Double](repeating: 0, count: m)
        var shared: [Int: Int] = [:]
        var multiCells: [(key: SIMD2<Int32>, cell: Cell)] = []

        for (key, cell) in cells where cell.entries.count >= 2 {
            let entries = cell.entries
            var weights: [Double] = []
            var heights: [Double] = []
            var total = 0.0
            for entry in entries {
                let w = Double(entry.sumWeight)
                weights.append(w)
                heights.append(Double(entry.sumWeightedHeight) / max(w, 0.001))
                total += w
            }
            guard total > 0 else { continue }
            multiCells.append((key, cell))
            let position = centre(of: key)
            let phi = SIMD3<Double>(1, Double(position.x - planeCentre.x), Double(position.y - planeCentre.y))
            for i in entries.indices {
                let ei = Int(entries[i].epoch)
                var accumulated = 0.0
                for j in entries.indices {
                    let ej = Int(entries[j].epoch)
                    let laplacian = (i == j ? weights[i] : 0) - weights[i] * weights[j] / total
                    for r in 0..<3 {
                        for c in 0..<3 { matrix[(3 * ei + r) * m + 3 * ej + c] += laplacian * phi[r] * phi[c] }
                    }
                    accumulated += laplacian * heights[j]
                    if i < j { shared[min(ei, ej) * n + max(ei, ej), default: 0] += 1 }
                }
                for r in 0..<3 { rhs[3 * ei + r] -= accumulated * phi[r] }
            }
        }

        func solve(allowTilt: Bool) -> [SIMD3<Float>] {
            var a = matrix
            for i in 0..<n {
                a[(3 * i) * m + 3 * i] += 1e-3                       // keeps unconnected passes at zero offset
                // Prior on tilt: about 1% grade, so weakly constrained passes stay flat.
                a[(3 * i + 1) * m + 3 * i + 1] += allowTilt ? Self.tiltPrior : 1e6
                a[(3 * i + 2) * m + 3 * i + 2] += allowTilt ? Self.tiltPrior : 1e6
            }
            for r in 0..<3 { a[r * m + r] += 1e6 }                    // pin the first pass completely
            let solved = Self.solveLinear(a, rhs, n: m) ?? [Double](repeating: 0, count: m)
            return (0..<n).map { i in
                func value(_ k: Int) -> Float { solved[3 * i + k].isFinite ? Float(solved[3 * i + k]) : 0 }
                return SIMD3<Float>(value(0), value(1), value(2))
            }
        }
        var solution = solve(allowTilt: true)
        // A tilt above 3% is more likely a poor fit than real drift: fall back to offsets only.
        if solution.contains(where: { abs($0.y) > Self.maximumTilt || abs($0.z) > Self.maximumTilt }) {
            solution = solve(allowTilt: false)
        }
        planes = solution

        // Passes sharing enough cells are linked; the component of the first pass is the reference.
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            return root
        }
        for (key, count) in shared where count >= Self.minimumSharedCells {
            let a = find(key / n), b = find(key % n)
            if a != b { parent[a] = b }
        }
        let reference = find(0)
        epochLinked = (0..<n).map { find($0) == reference }

        var raw: [Float] = [], residual: [Float] = []
        var loopRawValues: [Float] = [], loopFixedValues: [Float] = []
        for (key, cell) in multiCells {
            let position = centre(of: key)
            var lowRaw = Float.infinity, highRaw = -Float.infinity
            var lowFixed = Float.infinity, highFixed = -Float.infinity
            var firstPass: (raw: Float, fixed: Float)?
            var latestPass: (epoch: Int32, raw: Float, fixed: Float)?
            for entry in cell.entries {
                let h = entry.sumWeightedHeight / max(entry.sumWeight, 0.001)
                let fixed = h + correction(epoch: entry.epoch, at: position)
                lowRaw = min(lowRaw, h); highRaw = max(highRaw, h)
                lowFixed = min(lowFixed, fixed); highFixed = max(highFixed, fixed)
                if entry.epoch == 0 { firstPass = (h, fixed) }
                if entry.epoch >= 2, entry.epoch > (latestPass?.epoch ?? -1) { latestPass = (entry.epoch, h, fixed) }
            }
            raw.append(highRaw - lowRaw)
            residual.append(highFixed - lowFixed)
            if let firstPass, let latestPass {
                loopRawValues.append(abs(latestPass.raw - firstPass.raw))
                loopFixedValues.append(abs(latestPass.fixed - firstPass.fixed))
            }
        }
        rawDrift = raw.count >= 20 ? Double(median(raw)) * 1000 : nil
        residualDrift = residual.count >= 20 ? Double(median(residual)) * 1000 : nil
        loopRaw = loopRawValues.count >= 15 ? Double(median(loopRawValues)) * 1000 : nil
        loopResidual = loopFixedValues.count >= 15 ? Double(median(loopFixedValues)) * 1000 : nil
        maxCorrection = planes.isEmpty ? nil : Double(planes.map { abs($0.x) }.max() ?? 0) * 1000
        maxTilt = planes.isEmpty ? nil : Double(planes.map { ($0.y * $0.y + $0.z * $0.z).squareRoot() }.max() ?? 0) * 100
    }

    /// Gaussian elimination with partial pivoting.
    static func solveLinear(_ matrix: [Double], _ rhs: [Double], n: Int) -> [Double]? {
        var a = matrix, b = rhs
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<max(n, column + 1) where abs(a[row * n + column]) > abs(a[pivot * n + column]) { pivot = row }
            guard abs(a[pivot * n + column]) > 1e-12 else { return nil }
            if pivot != column {
                for k in 0..<n { a.swapAt(column * n + k, pivot * n + k) }
                b.swapAt(column, pivot)
            }
            for row in (column + 1)..<max(n, column + 1) {
                let factor = a[row * n + column] / a[column * n + column]
                if factor == 0 { continue }
                for k in column..<n { a[row * n + k] -= factor * a[column * n + k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<max(n, row + 1) { sum -= a[row * n + k] * x[k] }
            x[row] = sum / a[row * n + row]
        }
        return x
    }

    // MARK: Output

    func summary() -> Summary {
        lock.lock(); defer { lock.unlock() }
        refreshIfNeeded()
        var good = 0, weak = 0, noisy = 0
        var covered = [Int](repeating: 0, count: zoneCentres.count)
        for (key, cell) in cells where cell.count >= Self.minimumObservations {
            switch quality(of: cell) {
            case .good: good += 1
            case .weak: weak += 1
            case .noisy: noisy += 1
            }
            if let zone = zoneOfCell[key], zone < covered.count { covered[zone] += 1 }
        }
        var zones: [ZoneStatus] = []
        for index in zoneCentres.indices {
            let total = zoneCellCounts[index]
            let fraction = Double(covered[index]) / Double(max(total, 1))
            let state: ZoneState = fraction >= Self.zoneCompletion ? .complete : (covered[index] > 0 ? .inProgress : .notStarted)
            let linked = epochZones.indices.contains { epochZones[$0] == index && $0 < epochLinked.count && epochLinked[$0] }
            zones.append(ZoneStatus(index: index, centre: zoneCentres[index], cellCount: total,
                                    coveredCount: covered[index], state: state, linked: linked))
        }
        return Summary(good: good, weak: weak, noisy: noisy, total: totalInside, driftMillimetres: rawDrift,
                       residualMillimetres: residualDrift, maxCorrectionMillimetres: maxCorrection,
                       maxTiltPercent: maxTilt, loopClosureMillimetres: loopRaw,
                       loopClosureResidualMillimetres: loopResidual, startPoint: startPoint,
                       latestEpochLinked: epochLinked.last ?? false, epochCount: epochZones.count, zones: zones)
    }

    /// Tile centres (local metres, drift-corrected heights) for rendering and the minimap.
    func tiles() -> (good: [MapTile], weak: [MapTile], noisy: [MapTile]) {
        lock.lock(); defer { lock.unlock() }
        refreshIfNeeded()
        let size = Self.cellSize
        var good: [MapTile] = [], weak: [MapTile] = [], noisy: [MapTile] = []
        for (key, cell) in cells where cell.count >= Self.minimumObservations {
            let tile = MapTile(x: (Float(key.x) + 0.5) * size, z: (Float(key.y) + 0.5) * size, y: correctedMean(cell, key: key))
            switch quality(of: cell) {
            case .good: good.append(tile)
            case .weak: weak.append(tile)
            case .noisy: noisy.append(tile)
            }
        }
        return (good, weak, noisy)
    }

    /// Final cells with drift-corrected heights. With `smooth`, a robust local fit then removes cell-to-cell noise.
    func exportCells(smooth: Bool = true) -> [MapCell] {
        lock.lock()
        refreshIfNeeded()
        let raw: [MapCell] = cells.compactMap { key, cell in
            guard cell.count >= Self.minimumObservations else { return nil }
            return MapCell(ix: Int(key.x), iz: Int(key.y), height: correctedMean(cell, key: key),
                           observations: cell.count, bestRange: cell.minRange, noise: noise(of: cell))
        }.sorted { ($0.iz, $0.ix) < ($1.iz, $1.ix) }
        lock.unlock()
        guard smooth else { return raw }
        let heights = SurfaceSmoother.smooth(cells: raw, cellSize: Self.cellSize)
        return zip(raw, heights).map {
            MapCell(ix: $0.ix, iz: $0.iz, height: $1, observations: $0.observations, bestRange: $0.bestRange, noise: $0.noise)
        }
    }

    /// Drift-corrected cells in the strip just outside the outline (not smoothed).
    func exportBandCells() -> [MapCell] {
        lock.lock(); defer { lock.unlock() }
        refreshIfNeeded()
        return bandCells.compactMap { key, cell in
            guard cell.count >= Self.minimumObservations else { return nil }
            return MapCell(ix: Int(key.x), iz: Int(key.y), height: correctedMean(cell, key: key),
                           observations: cell.count, bestRange: cell.minRange, noise: noise(of: cell))
        }.sorted { ($0.iz, $0.ix) < ($1.iz, $1.ix) }
    }
}

enum ZoneGuidance {
    /// Tells the user which zone to scan or link next, and which zone to highlight.
    static func message(zones: [ZoneStatus], user: SIMD2<Float>?) -> (text: String, highlight: Int?) {
        guard zones.count > 1 else { return ("Walk the inside and cover the grey areas on the map.", nil) }

        func nearest(_ candidates: [ZoneStatus]) -> ZoneStatus? {
            guard let user else { return candidates.first }
            return candidates.min { simd_distance($0.centre, user) < simd_distance($1.centre, user) }
        }

        let unlinked = zones.filter { $0.state != .notStarted && !$0.linked }
        if let zone = nearest(unlinked) {
            let linked = zones.filter { $0.linked && $0.index != zone.index }
            if let neighbour = linked.min(by: { simd_distance($0.centre, zone.centre) < simd_distance($1.centre, zone.centre) }) {
                return ("Zone \(zone.index + 1) is not linked yet. Walk across its boundary with zone \(neighbour.index + 1) so heights can be matched.", zone.index)
            }
        }
        if let zone = nearest(zones.filter { $0.state == .inProgress }) {
            return ("Finish zone \(zone.index + 1): \(zone.coverage.formatted(.percent.precision(.fractionLength(0)))) scanned.", zone.index)
        }
        if let zone = nearest(zones.filter { $0.state == .notStarted }) {
            return ("Next: zone \(zone.index + 1). Start by overlapping the edge of the last zone.", zone.index)
        }
        return ("All zones complete. Tap Finish when you are ready.", nil)
    }
}
