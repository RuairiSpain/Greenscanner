import Foundation
import simd

/// One cell of a mapped green. Encoded as a compact array to keep exported files small.
struct MapCell: Codable, Sendable {
    let ix: Int
    let iz: Int
    /// Height in metres relative to the first edge point.
    let height: Float
    let observations: Int
    /// Closest camera distance, in metres, at which this cell was observed.
    let bestRange: Float
    /// Standard deviation, in metres, of this cell's height between frames of the same pass.
    let noise: Float?

    init(ix: Int, iz: Int, height: Float, observations: Int, bestRange: Float, noise: Float? = nil) {
        self.ix = ix; self.iz = iz; self.height = height
        self.observations = observations; self.bestRange = bestRange; self.noise = noise
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        ix = try container.decode(Int.self)
        iz = try container.decode(Int.self)
        height = try container.decode(Float.self)
        observations = try container.decode(Int.self)
        bestRange = try container.decode(Float.self)
        noise = container.isAtEnd ? nil : try container.decode(Float.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(ix)
        try container.encode(iz)
        try container.encode(height)
        try container.encode(observations)
        try container.encode(bestRange)
        if let noise { try container.encode(noise) }
    }
}

struct EdgePoint: Codable, Sendable {
    let x: Float
    let z: Float
    /// Height in metres relative to the first edge point, when known, so the border can be drawn in 3D.
    var y: Float? = nil
    var vector: SIMD2<Float> { SIMD2<Float>(x, z) }
}

/// A saved scan of one green. Coordinates are metres relative to the first edge point.
/// When `headingAligned` is true, +x is east and +z is south, so scans of the same green can later be
/// aligned using the origin coordinate and the edge outline.
struct GreenMapRecord: Codable, Identifiable, Sendable {
    static let currentFormat = 1

    var format: Int = GreenMapRecord.currentFormat
    let id: UUID
    var courseName: String
    var holeNumber: Int
    let createdAt: Date
    let cellSize: Float
    var edge: [EdgePoint]
    var cells: [MapCell]
    var coverage: Double
    var qualityScore: Double
    let driftMillimetres: Double?
    let trackingLossCount: Int
    var isPartial: Bool
    let headingAligned: Bool
    let originLatitude: Double?
    let originLongitude: Double?
    /// Set on merged greens: the scans that were combined.
    var sourceIDs: [UUID]? = nil
    var sourceScanCount: Int? = nil
    /// Zone workflow results: zone count, height spread between passes after correction, the largest
    /// vertical correction applied, and zones that could not be tied to the rest of the scan.
    var zoneCount: Int? = nil
    var residualMillimetres: Double? = nil
    var maxCorrectionMillimetres: Double? = nil
    var unlinkedZones: Int? = nil
    /// Capture settings, kept so scans made with different depth sources or devices can be compared.
    var depthSource: String? = nil
    var deviceModel: String? = nil
    /// Cup position if the user marked it, in the same frame as the outline.
    var cup: EdgePoint? = nil
    /// Drift tests: height difference where the walk looped back to its first pass (raw and corrected), and the
    /// largest tilt correction applied to any pass.
    var loopClosureMillimetres: Double? = nil
    var loopClosureResidualMillimetres: Double? = nil
    var maxTiltPercent: Double? = nil
    /// Cells in the 1 m strip just outside the outline, kept so the outline can be refined or edited later.
    var outerCells: [MapCell]? = nil
    /// How the outline was made: "walked", "refined" (snapped to detected fringe) or "edited" (by hand).
    var edgeSource: String? = nil
    /// When the cup position was marked. Pins move, so this dates the cup.
    var pinDate: Date? = nil
    /// Low-resolution top-down colour image of the green, if captured.
    var image: GreenImage? = nil
    var metadata: ScanMetadata? = nil

    var edgeVector: [SIMD2<Float>] { edge.map(\.vector) }
}

/// Conditions the walker can record; they affect both depth quality and how fast the green plays.
struct ScanConditions: Codable, Sendable, Equatable {
    /// "dry", "dew", "damp" or "wet".
    var surface: String? = nil
    /// "bright", "overcast" or "low".
    var light: String? = nil
    var stimpFeet: Double? = nil
}

struct ScanMetadata: Codable, Sendable {
    var appVersion: String
    var osVersion: String
    var startedAt: Date
    var durationSeconds: Double
    var framesProcessed: Int
    var hottestThermalState: String
    var conditions: ScanConditions = ScanConditions()

    static func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

enum DepthSource: String, CaseIterable, Identifiable, Sendable {
    case raw
    case smoothed

    var id: String { rawValue }
    var label: String { self == .raw ? "Raw LiDAR depth" : "Smoothed depth (temporal filter)" }
}

enum MapPhase: Equatable {
    case edge
    case scanning
    case review
}

struct MapTile: Sendable {
    let x: Float
    let z: Float
    let y: Float
}

/// What the minimap draws. Equality compares `version` only so SwiftUI can skip redrawing large cell sets.
struct MiniMapSnapshot: Equatable, Sendable {
    var version = 0
    var polygon: [SIMD2<Float>] = []
    var closed = false
    var good: [SIMD2<Float>] = []
    var weak: [SIMD2<Float>] = []
    var noisy: [SIMD2<Float>] = []
    var walkPath: [SIMD2<Float>] = []
    var cup: SIMD2<Float>?
    var start: SIMD2<Float>?
    var recovery: SIMD2<Float>?
    var zones: [ZoneStatus] = []
    var highlightZone: Int?
    var cellSize: Float = GreenMapAccumulator.cellSize

    static let empty = MiniMapSnapshot()
    static func == (lhs: MiniMapSnapshot, rhs: MiniMapSnapshot) -> Bool { lhs.version == rhs.version }
}

enum MapQuality {
    /// 0...1. Rewards inside-the-edge coverage and close-range observations, and penalises
    /// measured height drift between revisits and tracking losses.
    static func score(coverage: Double, goodShare: Double, driftMillimetres: Double?, trackingLosses: Int,
                     unlinkedZones: Int = 0) -> Double {
        let drift: Double
        if let driftMillimetres {
            drift = (1 - (driftMillimetres - 5) / 25).clamped(to: 0.3...1)
        } else {
            drift = 1
        }
        let losses = max(0.5, 1 - 0.1 * Double(trackingLosses))
        let linkage = max(0.6, 1 - 0.1 * Double(unlinkedZones))
        return (coverage * (0.5 + 0.5 * goodShare) * drift * losses * linkage).clamped(to: 0...1)
    }
}

enum MapSlope {
    /// Grade magnitude for every cell, using a 0.4 m baseline where possible to suppress depth noise.
    static func grades(cells: [MapCell], cellSize: Float) -> [Float] {
        gradientVectors(cells: cells, cellSize: cellSize).map { vector in
            guard let vector else { return 0 }
            return (vector.x * vector.x + vector.y * vector.y).squareRoot()
        }
    }

    /// Grade (rise over run) along x and z for every cell. An axis without neighbours counts as zero;
    /// a cell with neither axis available returns nil.
    static func gradientVectors(cells: [MapCell], cellSize: Float) -> [SIMD2<Float>?] {
        var lookup: [SIMD2<Int32>: Float] = [:]
        lookup.reserveCapacity(cells.count)
        for cell in cells { lookup[SIMD2<Int32>(Int32(cell.ix), Int32(cell.iz))] = cell.height }

        func axisGrade(_ cell: MapCell, dx: Int32, dz: Int32) -> Float? {
            for radius in [Int32(2), Int32(1)] {
                let plus = SIMD2<Int32>(Int32(cell.ix) + radius * dx, Int32(cell.iz) + radius * dz)
                let minus = SIMD2<Int32>(Int32(cell.ix) - radius * dx, Int32(cell.iz) - radius * dz)
                if let a = lookup[plus], let b = lookup[minus] {
                    return (a - b) / (2 * Float(radius) * cellSize)
                }
            }
            return nil
        }

        return cells.map { cell in
            let gx = axisGrade(cell, dx: 1, dz: 0)
            let gz = axisGrade(cell, dx: 0, dz: 1)
            if gx == nil && gz == nil { return nil }
            return SIMD2<Float>(gx ?? 0, gz ?? 0)
        }
    }
}
