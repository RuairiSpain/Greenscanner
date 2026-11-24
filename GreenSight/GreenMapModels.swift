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

    init(ix: Int, iz: Int, height: Float, observations: Int, bestRange: Float) {
        self.ix = ix; self.iz = iz; self.height = height
        self.observations = observations; self.bestRange = bestRange
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        ix = try container.decode(Int.self)
        iz = try container.decode(Int.self)
        height = try container.decode(Float.self)
        observations = try container.decode(Int.self)
        bestRange = try container.decode(Float.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(ix)
        try container.encode(iz)
        try container.encode(height)
        try container.encode(observations)
        try container.encode(bestRange)
    }
}

struct EdgePoint: Codable, Sendable {
    let x: Float
    let z: Float
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
    let edge: [EdgePoint]
    let cells: [MapCell]
    let coverage: Double
    let qualityScore: Double
    let driftMillimetres: Double?
    let trackingLossCount: Int
    let isPartial: Bool
    let headingAligned: Bool
    let originLatitude: Double?
    let originLongitude: Double?
    /// Set on merged greens: the scans that were combined.
    var sourceIDs: [UUID]? = nil
    var sourceScanCount: Int? = nil

    var edgeVector: [SIMD2<Float>] { edge.map(\.vector) }
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
    var cellSize: Float = GreenMapAccumulator.cellSize

    static let empty = MiniMapSnapshot()
    static func == (lhs: MiniMapSnapshot, rhs: MiniMapSnapshot) -> Bool { lhs.version == rhs.version }
}

enum MapQuality {
    /// 0...1. Rewards inside-the-edge coverage and close-range observations, and penalises
    /// measured height drift between revisits and tracking losses.
    static func score(coverage: Double, goodShare: Double, driftMillimetres: Double?, trackingLosses: Int) -> Double {
        let drift: Double
        if let driftMillimetres {
            drift = (1 - (driftMillimetres - 5) / 25).clamped(to: 0.3...1)
        } else {
            drift = 1
        }
        let losses = max(0.5, 1 - 0.1 * Double(trackingLosses))
        return (coverage * (0.5 + 0.5 * goodShare) * drift * losses).clamped(to: 0...1)
    }
}

enum MapSlope {
    /// Grade magnitude for every cell, using a 0.4 m baseline where possible to suppress depth noise.
    static func grades(cells: [MapCell], cellSize: Float) -> [Float] {
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
            let gx = axisGrade(cell, dx: 1, dz: 0) ?? 0
            let gz = axisGrade(cell, dx: 0, dz: 1) ?? 0
            return (gx * gx + gz * gz).squareRoot()
        }
    }
}
