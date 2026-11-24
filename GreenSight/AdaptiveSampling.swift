import Foundation
import simd

/// How much work scanning may do at a given device temperature.
struct ThermalPolicy: Sendable, Equatable {
    /// Shortest gap between processed frames, in seconds.
    let minimumInterval: Double
    /// Added to the depth sampling stride (higher = fewer depth pixels read).
    let extraStride: Int
    /// Gap between map, overlay and minimap refreshes, in seconds.
    let publishInterval: Double
    /// Multiplier on how often drafts are saved.
    let checkpointScale: Double
    let sampleColour: Bool
    /// False when the phone is too hot to keep processing depth.
    let processing: Bool
    let warning: String?

    init(state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            self.init(minimumInterval: 0.1, extraStride: 0, publishInterval: 1, checkpointScale: 1,
                      sampleColour: true, processing: true, warning: nil)
        case .fair:
            self.init(minimumInterval: 0.15, extraStride: 1, publishInterval: 1.5, checkpointScale: 1.5,
                      sampleColour: true, processing: true, warning: nil)
        case .serious:
            self.init(minimumInterval: 0.4, extraStride: 2, publishInterval: 3, checkpointScale: 2,
                      sampleColour: false, processing: true,
                      warning: "The phone is hot, so scanning is slowed down. Shade it or let it cool if you can.")
        default:
            self.init(minimumInterval: 1, extraStride: 3, publishInterval: 5, checkpointScale: 3,
                      sampleColour: false, processing: false,
                      warning: "The phone is too hot. Scanning is paused so it can cool; progress is saved.")
        }
    }

    private init(minimumInterval: Double, extraStride: Int, publishInterval: Double, checkpointScale: Double,
                 sampleColour: Bool, processing: Bool, warning: String?) {
        self.minimumInterval = minimumInterval
        self.extraStride = extraStride
        self.publishInterval = publishInterval
        self.checkpointScale = checkpointScale
        self.sampleColour = sampleColour
        self.processing = processing
        self.warning = warning
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Orders states so the hottest seen can be tracked.
    var rank: Int {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 3
        }
    }
}

/// Decides which camera frames are worth processing and how coarsely to read their depth.
///
/// A frame is processed when the camera has moved or turned enough to show new ground, or when it has been
/// still for a while (more frames of the same view average out noise). Once most of the green is covered,
/// depth is read more coarsely because passes mostly refine what is already known.
struct AdaptiveSampler {
    struct Decision: Equatable {
        let process: Bool
        let stride: Int
    }

    static let movementThreshold: Float = 0.10   // metres
    static let turnThreshold: Float = 5          // degrees
    static let idleInterval: Double = 1.0        // seconds
    static let baseStride = 3
    static let refinementStride = 4
    static let refinementCoverage = 0.85
    static let maximumStride = 6

    private var lastPosition: SIMD3<Float>?
    private var lastForward: SIMD3<Float>?
    private var lastTime = -Double.infinity

    mutating func reset() { self = AdaptiveSampler() }

    mutating func decide(transform: simd_float4x4, timestamp: Double, coverage: Double, policy: ThermalPolicy) -> Decision {
        let column = transform.columns.3
        let position = SIMD3<Float>(column.x, column.y, column.z)
        let back = transform.columns.2
        let forward = simd_normalize(-SIMD3<Float>(back.x, back.y, back.z))
        let stride = min(Self.maximumStride,
                         (coverage >= Self.refinementCoverage ? Self.refinementStride : Self.baseStride) + policy.extraStride)

        let elapsed = timestamp - lastTime
        guard elapsed >= policy.minimumInterval else { return Decision(process: false, stride: stride) }

        var novel = true
        if let lastPosition, let lastForward {
            let moved = simd_distance(position, lastPosition)
            let turned = acos(simd_dot(forward, lastForward).clamped(to: -1...1)) * 180 / .pi
            novel = moved >= Self.movementThreshold || turned >= Self.turnThreshold
        }
        guard novel || elapsed >= Self.idleInterval else { return Decision(process: false, stride: stride) }

        lastPosition = position
        lastForward = forward
        lastTime = timestamp
        return Decision(process: true, stride: stride)
    }
}
