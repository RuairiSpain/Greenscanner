import Foundation
import simd

/// Smooth height lookup over a saved green's cell grid.
struct HeightField: Sendable {
    let cellSize: Float
    private let lookup: [SIMD2<Int32>: Float]

    init(cells: [MapCell], cellSize: Float) {
        self.cellSize = cellSize
        var table: [SIMD2<Int32>: Float] = [:]
        table.reserveCapacity(cells.count)
        for cell in cells { table[SIMD2<Int32>(Int32(cell.ix), Int32(cell.iz))] = cell.height }
        lookup = table
    }

    init(record: GreenMapRecord) { self.init(cells: record.cells, cellSize: record.cellSize) }

    /// Bilinear between the four nearest cell centres, or a distance-weighted average near gaps and edges.
    func height(at point: SIMD2<Float>) -> Float? {
        let gx = point.x / cellSize - 0.5, gz = point.y / cellSize - 0.5
        let x0 = Int32(floor(gx)), z0 = Int32(floor(gz))
        let tx = gx - Float(x0), tz = gz - Float(z0)
        if let h00 = lookup[SIMD2<Int32>(x0, z0)], let h10 = lookup[SIMD2<Int32>(x0 + 1, z0)],
           let h01 = lookup[SIMD2<Int32>(x0, z0 + 1)], let h11 = lookup[SIMD2<Int32>(x0 + 1, z0 + 1)] {
            return (1 - tz) * ((1 - tx) * h00 + tx * h10) + tz * ((1 - tx) * h01 + tx * h11)
        }
        var weighted: Float = 0, total: Float = 0
        for dx in Int32(-1)...2 {
            for dz in Int32(-1)...2 {
                let key = SIMD2<Int32>(x0 + dx, z0 + dz)
                guard let height = lookup[key] else { continue }
                let centre = SIMD2<Float>((Float(key.x) + 0.5) * cellSize, (Float(key.y) + 0.5) * cellSize)
                let distance = simd_distance(centre, point)
                guard distance <= 1.5 * cellSize else { continue }
                let weight = 1 / (distance * distance + 1e-4)
                weighted += height * weight
                total += weight
            }
        }
        return total > 0 ? weighted / total : nil
    }
}

struct PlannedPutt: Sendable {
    let ball: SIMD2<Float>
    let cup: SIMD2<Float>
    let solution: PuttSolution
    /// The ball's path in map coordinates.
    let path: [SIMD2<Float>]
    /// Where the aim line is when it reaches the cup's distance, in map coordinates.
    let aimPoint: SIMD2<Float>
    let distanceMetres: Double
    /// How far the path strays from the straight ball-to-cup line at most, in centimetres.
    let breakCentimetres: Double
    /// Height of the cup above the ball in centimetres (negative = downhill), if both are known.
    let elevationChangeCentimetres: Double?
    /// Share of the putting corridor that was actually scanned, 0...1.
    let corridorCoverage: Double
    let notes: [String]
}

enum PuttPlanError: LocalizedError, Equatable {
    case notOnGreen
    case tooClose
    case tooFar
    case sparseData

    var errorDescription: String? {
        switch self {
        case .notOnGreen: return "Put the ball and the cup inside the green outline."
        case .tooClose: return "The ball and cup are too close together."
        case .tooFar: return "That putt is longer than 25 m."
        case .sparseData: return "This part of the green was not scanned well enough to plan a putt here."
        }
    }
}

/// Plans a putt on a saved green: cuts a corridor of the stored surface along the ball-to-cup line and runs it
/// through the same rolling model and optimiser the live reader uses.
enum PuttPlanner {
    static let gridSize: Float = 0.1
    static let minimumCorridorCoverage = 0.6
    static let onGreenTolerance: Float = 0.3

    static func plan(record: GreenMapRecord, ball: SIMD2<Float>, cup: SIMD2<Float>, stimpFeet: Double,
                     field: HeightField? = nil, now: Date = Date()) throws -> PlannedPutt {
        let polygon = record.edgeVector
        func onGreen(_ p: SIMD2<Float>) -> Bool {
            GreenGeometry.contains(polygon, point: p) || GreenGeometry.distance(from: p, toBoundaryOf: polygon) <= onGreenTolerance
        }
        guard onGreen(ball), onGreen(cup) else { throw PuttPlanError.notOnGreen }
        let delta = cup - ball
        let distance = simd_length(delta)
        guard distance >= 0.5 else { throw PuttPlanError.tooClose }
        guard distance <= 25 else { throw PuttPlanError.tooFar }

        // Same handedness as the live reader: facing the cup, the golfer's right is (-forward.z, forward.x).
        let forward = delta / distance
        let right = SIMD2<Float>(-forward.y, forward.x)
        let field = field ?? HeightField(record: record)

        let h = gridSize
        let halfWidth = min(3.0, max(1.5, 0.15 * distance))
        let nx = Int(halfWidth / h)
        let yMin = -6, yMax = Int((distance + 1.0) / h)

        var cells: [HeightCell] = []
        cells.reserveCapacity((2 * nx + 1) * (yMax - yMin + 1))
        var laneTotal = 0, laneAvailable = 0
        for ix in -nx...nx {
            for iy in yMin...yMax {
                let local = SIMD2<Float>(Float(ix) * h, Float(iy) * h)
                let mapPoint = ball + right * local.x + forward * local.y
                let height = field.height(at: mapPoint)
                let inLane = abs(local.x) <= 0.5 && local.y >= 0 && local.y <= distance
                if inLane { laneTotal += 1 }
                guard let height else { continue }
                if inLane { laneAvailable += 1 }
                cells.append(HeightCell(x: ix, y: iy, height: height, variance: 0, observations: 10))
            }
        }
        let coverage = laneTotal > 0 ? Double(laneAvailable) / Double(laneTotal) : 0
        guard coverage >= minimumCorridorCoverage else { throw PuttPlanError.sparseData }

        let snapshot = HeightMapSnapshot(cellSize: h, cells: cells, minX: -nx, maxX: nx, minY: yMin, maxY: yMax,
                                         coverage: min(1, coverage * min(1, record.coverage / 0.85 + 0.15)))
        let physics = PuttingPhysics(surface: GreenSurface(snapshot: snapshot),
                                     cup: SIMD2<Double>(0, Double(distance)), stimpFeet: stimpFeet)
        let solution = TrajectoryOptimizer(physics: physics).solve()

        let path = solution.path.map { ball + right * $0.x + forward * $0.y }
        let angle = Float(solution.launchAngleDegrees * .pi / 180)
        let aimDirection = right * sin(angle) + forward * cos(angle)
        let breakMetres = solution.path.map { abs($0.x) }.max() ?? 0

        var elevation: Double?
        if let ballHeight = field.height(at: ball), let cupHeight = field.height(at: cup) {
            elevation = Double(cupHeight - ballHeight) * 100
        }

        var notes: [String] = []
        if record.isPartial { notes.append("This green was only partly scanned.") }
        if coverage < 0.9 { notes.append("Part of the line has no scan data, so the break may be off.") }
        if let pin = record.pinDate {
            let days = Int(now.timeIntervalSince(pin) / 86_400)
            if days >= 1 { notes.append("The cup position was marked \(days) day(s) ago. Pins move: tap to place the cup where it is now.") }
        }
        if let drift = record.residualMillimetres, drift > 8 {
            notes.append(String(format: "The scan had about %.0f mm of height drift between passes.", drift))
        }
        if !solution.holed { notes.append("No line reaches the cup in this model. The best line is shown.") }

        return PlannedPutt(ball: ball, cup: cup, solution: solution, path: path, aimPoint: ball + aimDirection * distance,
                           distanceMetres: Double(distance), breakCentimetres: Double(breakMetres) * 100,
                           elevationChangeCentimetres: elevation, corridorCoverage: coverage, notes: notes)
    }
}

/// A short description of how a saved green lies.
struct GreenSummary: Sendable {
    let areaSquareMetres: Double
    let meanGradePercent: Double
    /// Gradient above which only 5% of cells lie.
    let steepGradePercent: Double
    /// Spread between the lowest and highest 5% of the surface, in centimetres.
    let elevationRangeCentimetres: Double
    /// Compass bearing the whole green falls toward, when the scan was north-aligned and the tilt is clear.
    let fallBearingDegrees: Double?
    let fallDescription: String

    static func make(from record: GreenMapRecord) -> GreenSummary? {
        guard record.cells.count >= 30 else { return nil }
        let grades = MapSlope.grades(cells: record.cells, cellSize: record.cellSize)
        let mean = Double(grades.reduce(0, +) / Float(grades.count)) * 100
        let steep = Double(percentile(grades, 0.95)) * 100
        let heights = record.cells.map(\.height)
        let range = Double(percentile(heights, 0.95) - percentile(heights, 0.05)) * 100
        let area = Double(GreenGeometry.area(record.edgeVector))

        var bearing: Double?
        var description = "No clear overall tilt"
        if let report = ValidationReport.make(from: record, expectedGradePercent: nil), report.planeGradePercent >= 0.3 {
            // planeDirectionDegrees is the uphill direction in map (x, z); the fall line is the opposite.
            let uphill = report.planeDirectionDegrees * .pi / 180
            let downX = -cos(uphill), downZ = -sin(uphill)
            if record.headingAligned {
                var compass = atan2(downX, -downZ) * 180 / .pi
                if compass < 0 { compass += 360 }
                bearing = compass
                description = String(format: "Falls toward the %@ at %.1f%%", compassName(compass), report.planeGradePercent)
            } else {
                description = String(format: "Tilts overall at %.1f%% (direction unknown: scan was not north-aligned)", report.planeGradePercent)
            }
        }
        return GreenSummary(areaSquareMetres: area, meanGradePercent: mean, steepGradePercent: steep,
                            elevationRangeCentimetres: range, fallBearingDegrees: bearing, fallDescription: description)
    }

    static func compassName(_ bearing: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        let index = Int(((bearing + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return names[max(0, min(names.count - 1, index))]
    }
}
