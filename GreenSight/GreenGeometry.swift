import Foundation
import simd

/// 2D polygon helpers for the green outline. Points are (x, z) in metres on the ground plane.
enum GreenGeometry {
    static func area(_ polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 3 else { return 0 }
        var sum: Float = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) * 0.5
    }

    static func contains(_ polygon: [SIMD2<Float>], point: SIMD2<Float>) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = index
        }
        return inside
    }

    /// Distance from a point to the nearest edge of a closed polygon.
    static func distance(from point: SIMD2<Float>, toBoundaryOf polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 2 else { return .infinity }
        var best = Float.infinity
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let ab = b - a
            let lengthSquared = simd_dot(ab, ab)
            let t = lengthSquared > 1e-12 ? (simd_dot(point - a, ab) / lengthSquared).clamped(to: 0...1) : 0
            best = min(best, simd_distance(point, a + ab * t))
        }
        return best
    }

    static func bounds(_ polygon: [SIMD2<Float>]) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        guard var low = polygon.first else { return nil }
        var high = low
        for point in polygon {
            low = simd_min(low, point)
            high = simd_max(high, point)
        }
        return (low, high)
    }

    /// True if any two non-adjacent edges of the closed polygon cross.
    static func selfIntersects(_ polygon: [SIMD2<Float>]) -> Bool {
        let count = polygon.count
        guard count >= 4 else { return false }
        for i in 0..<count {
            let a = polygon[i]
            let b = polygon[(i + 1) % count]
            var j = i + 1
            while j < count {
                let adjacent = (j == i + 1) || (i == 0 && j == count - 1)
                if !adjacent {
                    let c = polygon[j]
                    let d = polygon[(j + 1) % count]
                    if segmentsIntersect(a, b, c, d) { return true }
                }
                j += 1
            }
        }
        return false
    }

    private static func orientation(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    static func segmentsIntersect(_ p1: SIMD2<Float>, _ p2: SIMD2<Float>,
                                  _ p3: SIMD2<Float>, _ p4: SIMD2<Float>) -> Bool {
        let d1 = orientation(p3, p4, p1)
        let d2 = orientation(p3, p4, p2)
        let d3 = orientation(p1, p2, p3)
        let d4 = orientation(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }
}
