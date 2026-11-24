import Foundation
import simd

/// Robust local-linear (LOESS-style) smoothing of a height grid.
///
/// Each cell is replaced by the value at its centre of a plane fitted to the cells within a small radius,
/// weighted by distance and observation count, with two bisquare passes to down-weight outliers. A plane
/// keeps broad slope and curvature at the scale of the radius while suppressing cell-to-cell depth noise.
enum SurfaceSmoother {
    static func smooth(cells: [MapCell], cellSize: Float, radiusCells: Int = 3) -> [Float] {
        var lookup: [SIMD2<Int32>: Int] = [:]
        lookup.reserveCapacity(cells.count)
        for (index, cell) in cells.enumerated() { lookup[SIMD2<Int32>(Int32(cell.ix), Int32(cell.iz))] = index }

        let radius = Double(radiusCells) + 1
        var result = cells.map(\.height)

        for (index, cell) in cells.enumerated() {
            struct Point { let dx: Double; let dz: Double; let h: Double; let w: Double }
            var points: [Point] = []
            for ox in -radiusCells...radiusCells {
                for oz in -radiusCells...radiusCells where ox * ox + oz * oz <= radiusCells * radiusCells {
                    let key = SIMD2<Int32>(Int32(cell.ix + ox), Int32(cell.iz + oz))
                    guard let j = lookup[key] else { continue }
                    let distance = (Double(ox * ox + oz * oz)).squareRoot() / radius
                    let tricube = pow(1 - pow(distance, 3), 3)
                    let weight = tricube * Double(min(max(cells[j].observations, 1), 20))
                    points.append(Point(dx: Double(ox) * Double(cellSize), dz: Double(oz) * Double(cellSize),
                                        h: Double(cells[j].height), w: weight))
                }
            }
            guard points.count >= 6 else { continue }

            var robust = [Double](repeating: 1, count: points.count)
            var estimate: Double?
            for _ in 0..<3 {
                var n = simd_double3x3(diagonal: SIMD3<Double>(repeating: 0))
                var rhs = SIMD3<Double>(0, 0, 0)
                for (k, p) in points.enumerated() {
                    let w = p.w * robust[k]
                    let v = SIMD3<Double>(1, p.dx, p.dz)
                    n += simd_double3x3(columns: (v * (v.x * w), v * (v.y * w), v * (v.z * w)))
                    rhs += v * (p.h * w)
                }
                guard abs(n.determinant) > 1e-12 else { estimate = nil; break }
                let solution = n.inverse * rhs
                estimate = solution.x
                let residuals = points.map { $0.h - (solution.x + solution.y * $0.dx + solution.z * $0.dz) }
                let sorted = residuals.map(abs).sorted()
                let mad = sorted[sorted.count / 2]
                let sigma = max(mad / 0.6745, 0.001)
                for (k, r) in residuals.enumerated() {
                    let u = r / (4.685 * sigma)
                    robust[k] = abs(u) < 1 ? pow(1 - u * u, 2) : 0
                }
            }
            if let estimate, estimate.isFinite { result[index] = Float(estimate) }
        }
        return result
    }
}
