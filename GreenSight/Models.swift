import Foundation
import simd

struct WorldSample: Sendable {
    let position: SIMD3<Float>
    let weight: Float
    /// Camera colour at this point (red, green, blue in 0...1), when colour sampling is on.
    var colour: SIMD3<Float>? = nil
}

struct GreenBasis: Sendable {
    let origin: SIMD3<Float>
    let forward: SIMD3<Float>
    let right: SIMD3<Float>

    init?(ball: SIMD3<Float>, cup: SIMD3<Float>) {
        var f = cup - ball
        f.y = 0
        let length = simd_length(f)
        guard length > 0.15 else { return nil }
        f /= length
        origin = ball
        forward = f
        // right = forward x up, so local +x is the golfer's right when facing the cup.
        right = SIMD3<Float>(-f.z, 0, f.x)
    }

    func local(_ world: SIMD3<Float>) -> SIMD3<Float> {
        let delta = world - origin
        return SIMD3<Float>(simd_dot(delta, right), simd_dot(delta, forward), delta.y)
    }

    func world(x: Float, along: Float, height: Float) -> SIMD3<Float> {
        origin + right * x + forward * along + SIMD3<Float>(0, height, 0)
    }
}

struct HeightCell: Identifiable, Codable, Sendable {
    let x: Int
    let y: Int
    let height: Float
    let variance: Float
    let observations: Int
    var id: String { "\(x):\(y)" }
}

struct HeightMapSnapshot: Codable, Sendable {
    let cellSize: Float
    let cells: [HeightCell]
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int
    let coverage: Double

    static let empty = HeightMapSnapshot(
        cellSize: 0.03, cells: [], minX: 0, maxX: 0, minY: 0, maxY: 0, coverage: 0
    )
}

struct TrajectoryPoint: Codable, Sendable {
    let x: Float
    let y: Float
    let speed: Float
}

struct PuttSolution: Codable, Sendable {
    let launchAngleDegrees: Double
    let launchSpeedMetresPerSecond: Double
    let aimOffsetCentimetres: Double
    let arrivalSpeedMetresPerSecond: Double
    let closestDistanceMetres: Double
    let holed: Bool
    let confidence: Double
    let path: [TrajectoryPoint]
    /// Share of perturbed runs (Stimp +/-1, aim +/-0.6 deg, speed +/-4%) that hole out. Nil in older saved reads.
    var holeProbability: Double? = nil
}

struct ScanRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let distanceMetres: Double
    let stimpFeet: Double
    let coverage: Double
    let solution: PuttSolution
    let surface: HeightMapSnapshot
    /// Optional course/hole name entered by the user.
    var label: String? = nil
}

enum ScanPhase: Equatable {
    case idle
    case markBall
    case markCup
    case scanning
    case processing
    case result
    case unsupported(String)

    var instruction: String {
        switch self {
        case .idle: return "Start a scan when the ball and cup are visible."
        case .markBall: return "Point at the ball and tap its centre."
        case .markCup: return "Point at the cup and tap its centre."
        case .scanning: return "Sweep slowly across the entire putting corridor."
        case .processing: return "Calculating the surface and putt…"
        case .result: return "Follow the line from the ball marker."
        case .unsupported(let reason): return reason
        }
    }
}

enum DetectionMode: Sendable {
    case ball
    case cup
}

struct LandmarkCandidate: Sendable {
    let normalizedCenter: CGPoint
    let confidence: Double
}
