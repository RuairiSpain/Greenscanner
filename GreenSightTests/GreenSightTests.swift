import XCTest
import simd
@testable import GreenSight

final class GreenSightTests: XCTestCase {
    func testBasisRoundTrip() throws {
        let ball = SIMD3<Float>(1, 0.2, -2)
        let cup = SIMD3<Float>(1, 0.25, -5)
        let basis = try XCTUnwrap(GreenBasis(ball: ball, cup: cup))
        let world = basis.world(x: 0.4, along: 1.7, height: 0.08)
        let local = basis.local(world)
        XCTAssertEqual(local.x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(local.y, 1.7, accuracy: 0.0001)
        XCTAssertEqual(local.z, 0.08, accuracy: 0.0001)
    }

    func testRightVectorPointsToGolfersRight() throws {
        // Facing -Z (forward), the golfer's right is +X in a right-handed, y-up world.
        let basis = try XCTUnwrap(GreenBasis(ball: SIMD3<Float>(0, 0, 0), cup: SIMD3<Float>(0, 0, -3)))
        XCTAssertEqual(basis.right.x, 1, accuracy: 0.0001)
        XCTAssertEqual(basis.right.z, 0, accuracy: 0.0001)
    }

    func testFlatSurfaceHasZeroGradient() {
        let snapshot = fixtureSurface { _, _ in 0 }
        let surface = GreenSurface(snapshot: snapshot)
        let gradient = surface.gradient(at: SIMD2<Double>(0, 1.5))
        XCTAssertEqual(gradient.x, 0, accuracy: 0.0001)
        XCTAssertEqual(gradient.y, 0, accuracy: 0.0001)
    }

    func testPlanarSurfaceRecoversGrade() {
        let snapshot = fixtureSurface { x, y in Float(0.02 * x - 0.01 * y) }
        let gradient = GreenSurface(snapshot: snapshot).gradient(at: SIMD2<Double>(0, 1.5))
        XCTAssertEqual(gradient.x, 0.02, accuracy: 0.002)
        XCTAssertEqual(gradient.y, -0.01, accuracy: 0.002)
    }

    func testFlatPuttOptimizesNearStraight() {
        let snapshot = fixtureSurface { _, _ in 0 }
        let physics = PuttingPhysics(surface: GreenSurface(snapshot: snapshot),
                                     cup: SIMD2<Double>(0, 2.5), stimpFeet: 10)
        let solution = TrajectoryOptimizer(physics: physics).solve()
        XCTAssertLessThan(abs(solution.launchAngleDegrees), 1.0)
        XCTAssertLessThan(solution.closestDistanceMetres, 0.08)
        XCTAssertGreaterThan(solution.launchSpeedMetresPerSecond, 0.5)
    }

    func testCrossSlopeRequiresOpposingAim() {
        let snapshot = fixtureSurface { x, _ in Float(0.025 * x) }
        let physics = PuttingPhysics(surface: GreenSurface(snapshot: snapshot),
                                     cup: SIMD2<Double>(0, 2.5), stimpFeet: 10)
        let solution = TrajectoryOptimizer(physics: physics).solve()
        XCTAssertGreaterThan(solution.launchAngleDegrees, 0.2)
    }

    func testAccumulatorRejectsFramesFromAnOldScan() throws {
        let accumulator = HeightMapAccumulator()
        let oldID = UUID()
        let currentID = UUID()
        let ball = SIMD3<Float>(0, 0, 0)
        let cup = SIMD3<Float>(0, 0, 2)
        let samples = (0..<8).map { index in
            WorldSample(position: SIMD3<Float>(Float(index) * 0.031, 0, 0.4), weight: 1)
        }

        XCTAssertTrue(accumulator.reset(ball: ball, cup: cup, scanID: oldID))
        accumulator.ingest(samples, scanID: oldID)
        accumulator.ingest(samples, scanID: oldID)
        XCTAssertEqual(accumulator.snapshot(scanID: oldID).cells.count, 8)

        XCTAssertTrue(accumulator.reset(ball: ball, cup: cup, scanID: currentID))
        accumulator.ingest(samples, scanID: oldID)
        accumulator.ingest(samples, scanID: oldID)
        XCTAssertTrue(accumulator.snapshot(scanID: currentID).cells.isEmpty)

        accumulator.ingest(samples, scanID: currentID)
        accumulator.ingest(samples, scanID: currentID)
        XCTAssertEqual(accumulator.snapshot(scanID: currentID).cells.count, 8)
    }

    private func fixtureSurface(height: (Double, Double) -> Float) -> HeightMapSnapshot {
        let size: Float = 0.03
        var cells: [HeightCell] = []
        for x in -50...50 {
            for y in -10...120 {
                cells.append(HeightCell(x: x, y: y,
                    height: height((Double(x) + 0.5) * Double(size), (Double(y) + 0.5) * Double(size)),
                    variance: 0, observations: 10))
            }
        }
        return HeightMapSnapshot(cellSize: size, cells: cells, minX: -50, maxX: 50,
                                 minY: -10, maxY: 120, coverage: 1)
    }
}
