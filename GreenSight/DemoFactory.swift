import Foundation
import simd

struct DemoFactory {
    static func surface(length: Double = 3.2) -> HeightMapSnapshot {
        let size: Float = 0.03
        let halfWidth = 24
        let rows = Int(length / Double(size)) + 12
        var cells: [HeightCell] = []
        for x in -halfWidth...halfWidth {
            for y in -5...rows {
                let px = Float(x) * size
                let py = Float(y) * size
                let height = 0.012 * py + 0.008 * sin(px * 2.5) - 0.006 * px * py
                cells.append(HeightCell(x: x, y: y, height: height, variance: 0.000004, observations: 8))
            }
        }
        return HeightMapSnapshot(cellSize: size, cells: cells, minX: -halfWidth, maxX: halfWidth,
                                 minY: -5, maxY: rows, coverage: 0.91)
    }

    static func solution(stimpFeet: Double = 10) -> (HeightMapSnapshot, PuttSolution) {
        let snapshot = surface()
        let surface = GreenSurface(snapshot: snapshot)
        let physics = PuttingPhysics(surface: surface, cup: SIMD2<Double>(0, 3.2), stimpFeet: stimpFeet)
        return (snapshot, TrajectoryOptimizer(physics: physics).solve())
    }
}
