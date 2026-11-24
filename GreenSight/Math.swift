import Foundation
import simd

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension SIMD2 where Scalar == Double {
    var length: Double { simd_length(self) }
    var normalized: SIMD2<Double> {
        let value = length
        return value > 1e-9 ? self / value : .zero
    }
}

func median(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) * 0.5
    }
    return sorted[middle]
}

func percentile(_ values: [Float], _ p: Double) -> Float {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[index.clamped(to: 0...(sorted.count - 1))]
}

func metresToFeet(_ value: Double) -> Double { value * 3.280_839_895 }
func feetToMetres(_ value: Double) -> Double { value / 3.280_839_895 }
