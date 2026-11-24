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

    func testSmoothingPreservesPlanarSurface() {
        var cells: [HeightCell] = []
        for x in -5...5 {
            for y in -5...5 {
                cells.append(HeightCell(x: x, y: y, height: Float(x) * 0.0006, variance: 0, observations: 5))
            }
        }
        let smoothed = HeightMapAccumulator.smoothed(cells)
        let interior = smoothed.first { $0.x == 0 && $0.y == 0 }
        XCTAssertEqual(interior?.height ?? 1, 0, accuracy: 1e-6)
        let neighbour = smoothed.first { $0.x == 2 && $0.y == 1 }
        XCTAssertEqual(neighbour?.height ?? 1, 0.0012, accuracy: 1e-6)
    }

    func testSmoothingReducesIsolatedSpike() {
        var cells: [HeightCell] = []
        for x in -3...3 {
            for y in -3...3 {
                cells.append(HeightCell(x: x, y: y, height: (x == 0 && y == 0) ? 0.01 : 0, variance: 0, observations: 5))
            }
        }
        let centre = HeightMapAccumulator.smoothed(cells).first { $0.x == 0 && $0.y == 0 }
        XCTAssertLessThan(centre?.height ?? 1, 0.0051)
    }

    func testCameraPointBackProjection() {
        let centre = DepthProjector.cameraPoint(u: 50, v: 40, depth: 2, fx: 100, fy: 100, cx: 50, cy: 40)
        XCTAssertEqual(centre.x, 0, accuracy: 1e-6)
        XCTAssertEqual(centre.y, 0, accuracy: 1e-6)
        XCTAssertEqual(centre.z, -2, accuracy: 1e-6)
        // Pixels below the principal point are below the optical axis (negative camera y).
        let below = DepthProjector.cameraPoint(u: 50, v: 90, depth: 2, fx: 100, fy: 100, cx: 50, cy: 40)
        XCTAssertLessThan(below.y, 0)
    }

    func testFarDepthIsDownWeighted() {
        XCTAssertEqual(DepthProjector.rangeWeight(depth: 1.0), 1, accuracy: 1e-6)
        XCTAssertLessThan(DepthProjector.rangeWeight(depth: 3.0), 0.3)
    }

    func testCaptureSpeedFallsWithOffset() {
        XCTAssertGreaterThan(PuttingPhysics.captureSpeed(offset: 0), PuttingPhysics.captureSpeed(offset: 1))
    }

    func testFlatPuttReportsHoleProbability() throws {
        let snapshot = fixtureSurface { _, _ in 0 }
        let physics = PuttingPhysics(surface: GreenSurface(snapshot: snapshot),
                                     cup: SIMD2<Double>(0, 2.0), stimpFeet: 10)
        let solution = TrajectoryOptimizer(physics: physics).solve()
        let chance = try XCTUnwrap(solution.holeProbability)
        XCTAssertGreaterThanOrEqual(chance, 0)
        XCTAssertLessThanOrEqual(chance, 1)
    }

    func testUnitFormatting() {
        XCTAssertEqual(UnitSystem.metric.distance(3.2), "3.2 m")
        XCTAssertEqual(UnitSystem.imperial.shortLength(0.0254), "1 in")
    }

    func testCSVHasHeaderAndOneRowPerCell() {
        let snapshot = fixtureSurface { _, _ in 0 }
        let solution = PuttSolution(launchAngleDegrees: 0, launchSpeedMetresPerSecond: 1, aimOffsetCentimetres: 0,
                                    arrivalSpeedMetresPerSecond: 0.5, closestDistanceMetres: 0, holed: true,
                                    confidence: 1, path: [])
        let record = ScanRecord(id: UUID(), createdAt: Date(), distanceMetres: 2, stimpFeet: 10,
                                coverage: 1, solution: solution, surface: snapshot)
        let lines = CSVExporter.surfaceCSV(for: record).split(separator: "\n")
        XCTAssertEqual(lines.first, "x_m,y_m,height_m,variance_m2,observations")
        XCTAssertEqual(lines.count, snapshot.cells.count + 1)
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
