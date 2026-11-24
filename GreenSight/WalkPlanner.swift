import Foundation
import simd

enum WalkMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case acrossGreen
    case fringeOnly

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .acrossGreen: return "Across"
        case .fringeOnly: return "Fringe only"
        }
    }
}

struct WalkPlan: Sendable {
    let mode: WalkMode
    /// Route in map-local metres (x, z).
    let path: [SIMD2<Float>]
    /// Points along the route, at most `WalkPlanner.waypointSpacing` apart and including every corner.
    let waypoints: [SIMD2<Float>]
    let lengthMetres: Float
    /// Share of the green within `WalkPlanner.reach` of the route.
    let reachableFraction: Double

    static let empty = WalkPlan(mode: .off, path: [], waypoints: [], lengthMetres: 0, reachableFraction: 0)
}

/// Plans where to walk while mapping.
///
/// "Across" sweeps parallel lanes over the green along its long axis, spaced so that neighbouring passes
/// overlap, and routes around the cup so nobody steps near the hole. "Fringe only" walks a line about a
/// metre outside the edge so the putting surface is not entered; it can only reach the outer band of the green.
enum WalkPlanner {
    static let laneSpacing: Float = 3.0
    /// Horizontal distance from the walker within which depth is usually good enough (phone about 1.5 m high).
    static let reach: Float = 3.0
    static let edgeInset: Float = 0.4
    static let cupKeepOut: Float = 1.2
    static let fringeOffset: Float = 1.0
    static let waypointSpacing: Float = 2.0

    static func plan(mode: WalkMode, polygon: [SIMD2<Float>], cup: SIMD2<Float>?, start: SIMD2<Float>?) -> WalkPlan {
        guard polygon.count >= 3, mode != .off else { return .empty }
        let path: [SIMD2<Float>]
        switch mode {
        case .acrossGreen: path = acrossPath(polygon: polygon, cup: cup, start: start)
        case .fringeOnly: path = fringePath(polygon: polygon, start: start)
        case .off: path = []
        }
        guard path.count >= 2 else { return .empty }
        let waypoints = resample(path, spacing: waypointSpacing)
        return WalkPlan(mode: mode, path: path, waypoints: waypoints, lengthMetres: length(of: path),
                        reachableFraction: reachableFraction(polygon: polygon, path: path))
    }

    // MARK: Across the green

    static func principalAngle(_ polygon: [SIMD2<Float>]) -> Float {
        // Drop the closing duplicate so one corner is not counted twice.
        let samples = Array(resample(polygon + [polygon[0]], spacing: 0.5).dropLast())
        let mean = samples.reduce(SIMD2<Float>.zero, +) / Float(max(samples.count, 1))
        var sxx: Float = 0, sxy: Float = 0, syy: Float = 0
        for p in samples {
            let d = p - mean
            sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y
        }
        return 0.5 * atan2(2 * sxy, sxx - syy)
    }

    static func acrossPath(polygon: [SIMD2<Float>], cup: SIMD2<Float>?, start: SIMD2<Float>?) -> [SIMD2<Float>] {
        let theta = principalAngle(polygon)
        let u = SIMD2<Float>(cos(theta), sin(theta))
        let v = SIMD2<Float>(-sin(theta), cos(theta))
        func toAB(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2<Float>(simd_dot(p, u), simd_dot(p, v)) }
        func fromAB(_ q: SIMD2<Float>) -> SIMD2<Float> { u * q.x + v * q.y }

        let ab = polygon.map(toAB)
        guard let bounds = GreenGeometry.bounds(ab) else { return [] }
        let bMin = bounds.min.y, bMax = bounds.max.y
        let span = max(bMax - bMin, 0.1)
        let laneCount = max(1, Int(ceil(span / laneSpacing - 0.1)))
        let cupAB = cup.map(toAB)
        let radius = cupKeepOut

        var lanes: [[SIMD2<Float>]] = []   // each lane: points in (a, b), ascending a
        for index in 0..<laneCount {
            let b = bMin + (Float(index) + 0.5) * span / Float(laneCount)
            var crossings: [Float] = []
            for k in ab.indices {
                let p = ab[k], q = ab[(k + 1) % ab.count]
                if (p.y <= b && q.y > b) || (q.y <= b && p.y > b) {
                    crossings.append(p.x + (b - p.y) / (q.y - p.y) * (q.x - p.x))
                }
            }
            crossings.sort()
            var intervals: [(Float, Float)] = []
            var j = 0
            while j + 1 < crossings.count {
                let a0 = crossings[j] + edgeInset, a1 = crossings[j + 1] - edgeInset
                if a1 - a0 >= 0.5 { intervals.append((a0, a1)) }
                j += 2
            }

            var detour: (cx: Float, points: [SIMD2<Float>])?
            if let c = cupAB, abs(c.y - b) < radius {
                let w = (radius * radius - (b - c.y) * (b - c.y)).squareRoot()
                var split: [(Float, Float)] = []
                for (a0, a1) in intervals {
                    if c.x + w <= a0 || c.x - w >= a1 { split.append((a0, a1)); continue }
                    if c.x - w - a0 >= 0.5 { split.append((a0, c.x - w)) }
                    if a1 - (c.x + w) >= 0.5 { split.append((c.x + w, a1)) }
                }
                intervals = split
                detour = (c.x, arc(around: c, radius: radius + 0.2, laneB: b, halfChord: w,
                                   preferUp: c.y < (bMin + bMax) / 2, inside: { GreenGeometry.contains(ab, point: $0) }))
            }

            var points: [SIMD2<Float>] = []
            for (n, interval) in intervals.enumerated() {
                if n > 0, let detour, let previous = points.last, previous.x <= detour.cx, interval.0 >= detour.cx {
                    points.append(contentsOf: detour.points)
                }
                points.append(SIMD2<Float>(interval.0, b))
                points.append(SIMD2<Float>(interval.1, b))
            }
            if !points.isEmpty { lanes.append(points) }
        }
        guard !lanes.isEmpty else { return [] }

        // Four ways to traverse the lanes; pick the one that begins nearest to the walker.
        var best: [SIMD2<Float>] = []
        var bestDistance = Float.infinity
        for reverseOrder in [false, true] {
            for firstAscending in [true, false] {
                let ordered = reverseOrder ? Array(lanes.reversed()) : lanes
                var path: [SIMD2<Float>] = []
                for (n, lane) in ordered.enumerated() {
                    let ascending = firstAscending == (n % 2 == 0)
                    path.append(contentsOf: (ascending ? lane : Array(lane.reversed())).map(fromAB))
                }
                let distance = start.map { simd_distance($0, path[0]) } ?? (reverseOrder || !firstAscending ? 1 : 0)
                if distance < bestDistance { bestDistance = distance; best = path }
            }
        }
        return removeDuplicates(best)
    }

    /// Half circle around the cup from one end of the broken lane to the other, on the side with room.
    private static func arc(around c: SIMD2<Float>, radius: Float, laneB: Float, halfChord w: Float,
                            preferUp: Bool, inside: (SIMD2<Float>) -> Bool) -> [SIMD2<Float>] {
        let y = laneB - c.y
        let a0 = atan2(y, -w), a1 = atan2(y, w)
        func points(up: Bool) -> [SIMD2<Float>] {
            let start: Float = up ? (a0 < 0 ? a0 + 2 * .pi : a0) : (a0 > 0 ? a0 - 2 * .pi : a0)
            return (0...6).map { step in
                let angle = start + (a1 - start) * Float(step) / 6
                return c + SIMD2<Float>(cos(angle), sin(angle)) * radius
            }
        }
        for up in [preferUp, !preferUp] {
            let candidate = points(up: up)
            if candidate.allSatisfy(inside) { return candidate }
        }
        return []
    }

    // MARK: Fringe only

    static func fringePath(polygon: [SIMD2<Float>], start: SIMD2<Float>?) -> [SIMD2<Float>] {
        let size: Float = 0.25
        guard let union = GreenOutline.union(polygons: [polygon], cellSize: size) else { return [] }
        let radius = Int((fringeOffset / size).rounded())
        var offsets: [SIMD2<Int32>] = []
        for dx in -radius...radius {
            for dz in -radius...radius where dx * dx + dz * dz <= radius * radius {
                offsets.append(SIMD2<Int32>(Int32(dx), Int32(dz)))
            }
        }
        var dilated = Set<SIMD2<Int32>>()
        dilated.reserveCapacity(union.cells.count * 2)
        for cell in union.cells {
            for offset in offsets { dilated.insert(cell &+ offset) }
        }
        let loop = GreenOutline.traceOuterLoop(dilated)
        guard loop.count >= 4 else { return [] }
        var points = GreenOutline.simplify(loop.map { SIMD2<Float>(Float($0.x) * size, Float($0.y) * size) }, tolerance: 0.3)
        guard points.count >= 3 else { return [] }
        if let start, let nearest = points.indices.min(by: { simd_distance(points[$0], start) < simd_distance(points[$1], start) }) {
            points = Array(points[nearest...]) + Array(points[..<nearest])
        }
        return points + [points[0]]
    }

    // MARK: Helpers

    static func length(of path: [SIMD2<Float>]) -> Float {
        zip(path, path.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }

    static func removeDuplicates(_ path: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var output: [SIMD2<Float>] = []
        for p in path where output.last.map({ simd_distance($0, p) > 0.01 }) ?? true { output.append(p) }
        return output
    }

    /// Points no more than `spacing` apart along a polyline; every original vertex is kept.
    static func resample(_ path: [SIMD2<Float>], spacing: Float) -> [SIMD2<Float>] {
        guard var previous = path.first else { return [] }
        var output = [previous]
        for point in path.dropFirst() {
            let distance = simd_distance(previous, point)
            let pieces = max(1, Int(ceil(distance / spacing)))
            for piece in 1...pieces {
                output.append(previous + (point - previous) * (Float(piece) / Float(pieces)))
            }
            previous = point
        }
        return output
    }

    static func reachableFraction(polygon: [SIMD2<Float>], path: [SIMD2<Float>]) -> Double {
        let mask = PolygonMask(polygon: polygon, cellSize: 0.5)
        let centres = mask.samplePoints(spacing: 0.5)
        guard !centres.isEmpty else { return 0 }
        let samples = resample(path, spacing: 0.5)
        let covered = centres.filter { centre in samples.contains { simd_distance($0, centre) <= reach } }.count
        return Double(covered) / Double(centres.count)
    }
}
