import Foundation
import simd

enum DeviceInfo {
    /// Hardware identifier such as "iPhone15,2".
    static var machine: String {
        var info = utsname()
        uname(&info)
        return Mirror(reflecting: info.machine).children.reduce("") { id, element in
            guard let value = element.value as? Int8, value != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(value)))
        }
    }
}

struct RangeBucketStats: Codable, Sendable {
    let label: String
    let cells: Int
    let rmsResidualMillimetres: Double
    let meanNoiseMillimetres: Double?
}

/// Error statistics for a scan of a surface whose slope is known (a level floor, or a board set to a
/// measured grade). The fitted plane gives the measured grade; the local-grade deviations show how much
/// slope noise a putt calculation would see.
struct ValidationReport: Codable, Sendable {
    let cellCount: Int
    let planeGradePercent: Double
    let planeDirectionDegrees: Double
    let expectedGradePercent: Double?
    let gradeErrorPercent: Double?
    let rmsResidualMillimetres: Double
    let robustSigmaMillimetres: Double
    let localGradeErrorMedianPercent: Double?
    let localGradeErrorP95Percent: Double?
    let buckets: [RangeBucketStats]
    let depthSource: String?
    let deviceModel: String?

    static let bucketEdges: [Float] = [1.5, 2.5, 3.5]

    static func make(from record: GreenMapRecord, expectedGradePercent: Double?) -> ValidationReport? {
        let cells = record.cells
        guard cells.count >= 30 else { return nil }
        let size = Double(record.cellSize)
        let xs = cells.map { (Double($0.ix) + 0.5) * size }
        let zs = cells.map { (Double($0.iz) + 0.5) * size }
        let hs = cells.map { Double($0.height) }
        let weights = cells.map { Double(min(max($0.observations, 1), 20)) }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanZ = zs.reduce(0, +) / Double(zs.count)

        func residual(_ i: Int, _ plane: SIMD3<Double>) -> Double {
            let predicted = plane.x + plane.y * (xs[i] - meanX) + plane.z * (zs[i] - meanZ)
            return hs[i] - predicted
        }

        // Robust (bisquare) weighted plane fit.
        var robust = [Double](repeating: 1, count: cells.count)
        var solution = SIMD3<Double>(0, 0, 0)
        for _ in 0..<4 {
            var n = simd_double3x3(diagonal: SIMD3<Double>(repeating: 0))
            var rhs = SIMD3<Double>(0, 0, 0)
            for i in cells.indices {
                let w = weights[i] * robust[i]
                let v = SIMD3<Double>(1, xs[i] - meanX, zs[i] - meanZ)
                n += simd_double3x3(columns: (v * (v.x * w), v * (v.y * w), v * (v.z * w)))
                rhs += v * (hs[i] * w)
            }
            guard abs(n.determinant) > 1e-9 else { return nil }
            solution = n.inverse * rhs
            let residuals = cells.indices.map { residual($0, solution) }
            let sorted = residuals.map(abs).sorted()
            let sigma = max(sorted[sorted.count / 2] / 0.6745, 0.0005)
            for i in cells.indices {
                let u = residuals[i] / (4.685 * sigma)
                robust[i] = abs(u) < 1 ? (1 - u * u) * (1 - u * u) : 0
            }
        }

        let residuals = cells.indices.map { residual($0, solution) }
        let rms = (residuals.map { $0 * $0 }.reduce(0, +) / Double(residuals.count)).squareRoot() * 1000
        let mad = residuals.map(abs).sorted()[residuals.count / 2] / 0.6745 * 1000

        let gradePercent = (solution.y * solution.y + solution.z * solution.z).squareRoot() * 100
        let direction = atan2(solution.z, solution.y) * 180 / .pi

        // Local grade deviation from the fitted plane, in percent grade.
        let vectors = MapSlope.gradientVectors(cells: cells, cellSize: record.cellSize)
        var deviations: [Float] = []
        for vector in vectors {
            guard let vector else { continue }
            let dx = Double(vector.x) - solution.y
            let dz = Double(vector.y) - solution.z
            deviations.append(Float((dx * dx + dz * dz).squareRoot() * 100))
        }

        var buckets: [RangeBucketStats] = []
        let edges = bucketEdges
        let labels = ["under 1.5 m", "1.5 to 2.5 m", "2.5 to 3.5 m", "over 3.5 m"]
        for bucket in 0..<labels.count {
            let indices = cells.indices.filter { index in
                let range = cells[index].bestRange
                let lower: Float = bucket == 0 ? -.infinity : edges[bucket - 1]
                let upper: Float = bucket == edges.count ? .infinity : edges[bucket]
                return range >= lower && range < upper
            }
            guard !indices.isEmpty else { continue }
            let bucketRms = (indices.map { residuals[$0] * residuals[$0] }.reduce(0, +) / Double(indices.count)).squareRoot() * 1000
            let noises = indices.compactMap { cells[$0].noise }
            let meanNoise = noises.isEmpty ? nil : Double(noises.reduce(0, +) / Float(noises.count)) * 1000
            buckets.append(RangeBucketStats(label: labels[bucket], cells: indices.count,
                                            rmsResidualMillimetres: bucketRms, meanNoiseMillimetres: meanNoise))
        }

        return ValidationReport(
            cellCount: cells.count, planeGradePercent: gradePercent, planeDirectionDegrees: direction,
            expectedGradePercent: expectedGradePercent,
            gradeErrorPercent: expectedGradePercent.map { gradePercent - $0 },
            rmsResidualMillimetres: rms, robustSigmaMillimetres: mad,
            localGradeErrorMedianPercent: deviations.isEmpty ? nil : Double(percentile(deviations, 0.5)),
            localGradeErrorP95Percent: deviations.isEmpty ? nil : Double(percentile(deviations, 0.95)),
            buckets: buckets, depthSource: record.depthSource, deviceModel: record.deviceModel)
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }
}
