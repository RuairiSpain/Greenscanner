import Foundation
import simd

/// Watches camera motion while scanning and reports when the user is moving too fast, turning too fast
/// or holding the phone too level. Depth from a fast-moving or grazing camera is noisier.
struct MotionCoach {
    enum Advice: Equatable {
        case turningTooFast, slowDown, tiltDown

        var message: String {
            switch self {
            case .turningTooFast: return "Turning too fast. Pan the phone slowly."
            case .slowDown: return "Walking too fast. Slow down for a cleaner scan."
            case .tiltDown: return "Tilt the phone down toward the grass."
            }
        }
    }

    static let maximumLinearSpeed: Float = 1.2      // metres per second
    static let maximumAngularSpeed: Float = 70      // degrees per second
    static let minimumDepression: Float = 20        // degrees below the horizon

    private var lastPosition: SIMD3<Float>?
    private var lastForward: SIMD3<Float>?
    private var lastTime: Double?
    private var linearSpeed: Float = 0
    private var angularSpeed: Float = 0
    private var depression: Float = 45
    private(set) var advice: Advice?

    mutating func reset() {
        self = MotionCoach()
    }

    /// Feed every camera pose. Returns the current advice, which only changes after smoothing.
    @discardableResult
    mutating func update(transform: simd_float4x4, timestamp: Double) -> Advice? {
        let column = transform.columns.3
        let position = SIMD3<Float>(column.x, column.y, column.z)
        let back = transform.columns.2
        let forward = simd_normalize(-SIMD3<Float>(back.x, back.y, back.z))
        let currentDepression = asin((-forward.y).clamped(to: -1...1)) * 180 / .pi

        defer { lastPosition = position; lastForward = forward; lastTime = timestamp }
        guard let lastPosition, let lastForward, let lastTime else {
            depression = currentDepression
            return advice
        }
        let dt = Float(timestamp - lastTime)
        guard dt > 0.001, dt < 0.5 else { return advice }

        let alpha: Float = 0.25
        let instantLinear = simd_distance(position, lastPosition) / dt
        let instantAngular = acos(simd_dot(forward, lastForward).clamped(to: -1...1)) * 180 / .pi / dt
        linearSpeed += alpha * (instantLinear - linearSpeed)
        angularSpeed += alpha * (instantAngular - angularSpeed)
        depression += alpha * (currentDepression - depression)

        // Hysteresis: advice clears only after the value is comfortably back in range.
        let turning = angularSpeed > Self.maximumAngularSpeed * (advice == .turningTooFast ? 0.8 : 1)
        let fast = linearSpeed > Self.maximumLinearSpeed * (advice == .slowDown ? 0.8 : 1)
        let level = depression < Self.minimumDepression + (advice == .tiltDown ? 4 : 0)
        if turning { advice = .turningTooFast }
        else if fast { advice = .slowDown }
        else if level { advice = .tiltDown }
        else { advice = nil }
        return advice
    }
}

/// Recent walker positions (map-local x, z), used to find where to return to after tracking is lost.
struct PositionTrail {
    private(set) var points: [(position: SIMD2<Float>, time: Double)] = []
    static let capacity = 40

    mutating func add(_ position: SIMD2<Float>, time: Double) {
        points.append((position, time))
        if points.count > Self.capacity { points.removeFirst(points.count - Self.capacity) }
    }

    mutating func reset() { points.removeAll() }

    /// The point about `distance` metres back along the walked path, or the oldest point if the trail is shorter.
    func point(distanceBack distance: Float) -> SIMD2<Float>? {
        guard var current = points.last?.position else { return nil }
        var travelled: Float = 0
        for entry in points.reversed().dropFirst() {
            let step = simd_distance(current, entry.position)
            if travelled + step >= distance {
                let t = step > 0 ? (distance - travelled) / step : 0
                return current + (entry.position - current) * t
            }
            travelled += step
            current = entry.position
        }
        return current
    }
}
