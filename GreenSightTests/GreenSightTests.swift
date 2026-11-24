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

    // MARK: Green mapping

    private let square: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(0, 4)]

    func testPolygonAreaAndContainment() {
        XCTAssertEqual(GreenGeometry.area(square), 16, accuracy: 1e-4)
        XCTAssertTrue(GreenGeometry.contains(square, point: SIMD2(2, 2)))
        XCTAssertFalse(GreenGeometry.contains(square, point: SIMD2(5, 2)))
    }

    func testSelfIntersectionDetection() {
        XCTAssertFalse(GreenGeometry.selfIntersects(square))
        let bowtie: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(4, 4), SIMD2(4, 0), SIMD2(0, 4)]
        XCTAssertTrue(GreenGeometry.selfIntersects(bowtie))
    }

    private func flatSamples(height: Float = 0) -> [WorldSample] {
        var samples: [WorldSample] = []
        var x: Float = 0.01
        while x < 4 {
            var z: Float = 0.01
            while z < 4 {
                samples.append(WorldSample(position: SIMD3<Float>(x, height, z), weight: 1))
                z += 0.05
            }
            x += 0.05
        }
        return samples
    }

    func testAccumulatorCoversInsideOfOutlineOnly() {
        let accumulator = GreenMapAccumulator()
        let id = UUID()
        accumulator.configure(polygon: square, origin: .zero, scanID: id)
        // Samples extend 1 m beyond the outline; only the inside may be counted.
        var samples = flatSamples()
        samples.append(WorldSample(position: SIMD3<Float>(6, 0, 6), weight: 1))
        for step in 0..<4 {
            accumulator.ingest(samples, camera: SIMD3<Float>(2, 1.5, 2), timestamp: Double(step), scanID: id)
        }
        let summary = accumulator.summary()
        XCTAssertEqual(summary.total, 400)
        XCTAssertGreaterThan(summary.coverage, 0.95)
        XCTAssertEqual(summary.weak, 0)
        XCTAssertTrue(accumulator.exportCells().allSatisfy { $0.ix >= 0 && $0.ix < 20 && $0.iz >= 0 && $0.iz < 20 })
    }

    func testFarObservationsAreWeakAndStaleScanIgnored() {
        let accumulator = GreenMapAccumulator()
        let id = UUID()
        accumulator.configure(polygon: square, origin: .zero, scanID: id)
        for step in 0..<4 {
            accumulator.ingest(flatSamples(), camera: SIMD3<Float>(2, 5, 2), timestamp: Double(step), scanID: id)
            accumulator.ingest(flatSamples(), camera: SIMD3<Float>(2, 1, 2), timestamp: Double(step), scanID: UUID())
        }
        let summary = accumulator.summary()
        XCTAssertEqual(summary.good, 0)
        XCTAssertGreaterThan(summary.weak, 300)
    }

    func testRevisitMeasuresDrift() {
        let accumulator = GreenMapAccumulator()
        let id = UUID()
        accumulator.configure(polygon: square, origin: .zero, scanID: id)
        for step in 0..<4 {
            accumulator.ingest(flatSamples(), camera: SIMD3<Float>(2, 1.5, 2), timestamp: Double(step), scanID: id)
        }
        accumulator.ingest(flatSamples(height: 0.02), camera: SIMD3<Float>(2, 1.5, 2), timestamp: 60, scanID: id)
        let drift = accumulator.summary().driftMillimetres
        XCTAssertNotNil(drift)
        XCTAssertEqual(drift ?? 0, 20, accuracy: 2)
    }

    func testQualityPenalisesDriftAndTrackingLoss() {
        let clean = MapQuality.score(coverage: 1, goodShare: 1, driftMillimetres: nil, trackingLosses: 0)
        let drifty = MapQuality.score(coverage: 1, goodShare: 1, driftMillimetres: 25, trackingLosses: 0)
        let lossy = MapQuality.score(coverage: 1, goodShare: 1, driftMillimetres: nil, trackingLosses: 4)
        XCTAssertEqual(clean, 1, accuracy: 1e-9)
        XCTAssertLessThan(drifty, clean)
        XCTAssertLessThan(lossy, clean)
    }

    func testMapSlopeRecoversGrade() {
        var cells: [MapCell] = []
        for ix in 0..<10 {
            for iz in 0..<10 {
                cells.append(MapCell(ix: ix, iz: iz, height: Float(ix) * 0.2 * 0.03, observations: 5, bestRange: 1))
            }
        }
        let grades = MapSlope.grades(cells: cells, cellSize: 0.2)
        XCTAssertEqual(grades[5 * 10 + 5], 0.03, accuracy: 0.001)
    }

    func testGreenRecordRoundTripsThroughJSON() throws {
        let record = GreenMapRecord(
            id: UUID(), courseName: "Test Links", holeNumber: 7, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            cellSize: 0.2, edge: square.map { EdgePoint(x: $0.x, z: $0.y) },
            cells: [MapCell(ix: 1, iz: 2, height: 0.05, observations: 4, bestRange: 1.2)],
            coverage: 0.9, qualityScore: 0.8, driftMillimetres: 4, trackingLossCount: 1,
            isPartial: false, headingAligned: true, originLatitude: 53.3, originLongitude: -6.2)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(GreenMapRecord.self, from: encoder.encode(record))
        XCTAssertEqual(decoded.courseName, "Test Links")
        XCTAssertEqual(decoded.cells.first?.iz, 2)
        XCTAssertEqual(decoded.cells.first?.height ?? 0, 0.05, accuracy: 1e-6)
        XCTAssertEqual(decoded.edge.count, 4)
    }

    // MARK: Merging

    /// Asymmetric L-shaped green in world metres.
    private let lShape: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(12, 0), SIMD2(12, 5), SIMD2(5, 5), SIMD2(5, 10), SIMD2(0, 10)]

    private func worldHeight(_ p: SIMD2<Float>) -> Float { 0.02 * p.x + 0.01 * p.y }

    /// Simulates a scan taken in a frame rotated by `angle` and shifted by `origin` from the world frame.
    private func syntheticScan(angle: Float, origin: SIMD2<Float>, verticalOffset: Float,
                               quality: Double = 0.8, clip: ((SIMD2<Float>) -> Bool)? = nil) -> GreenMapRecord {
        let c = cos(angle), s = sin(angle)
        func toWorld(_ l: SIMD2<Float>) -> SIMD2<Float> { SIMD2(c * l.x - s * l.y, s * l.x + c * l.y) + origin }
        func toLocal(_ w: SIMD2<Float>) -> SIMD2<Float> {
            let d = w - origin
            return SIMD2(c * d.x + s * d.y, -s * d.x + c * d.y)
        }
        let polygon = lShape.map(toLocal)
        let size: Float = 0.2
        var cells: [MapCell] = []
        let bounds = GreenGeometry.bounds(polygon)!
        for ix in Int(floor(bounds.min.x / size))...Int(floor(bounds.max.x / size)) {
            for iz in Int(floor(bounds.min.y / size))...Int(floor(bounds.max.y / size)) {
                let local = SIMD2<Float>((Float(ix) + 0.5) * size, (Float(iz) + 0.5) * size)
                guard GreenGeometry.contains(polygon, point: local) else { continue }
                let world = toWorld(local)
                if let clip, !clip(world) { continue }
                cells.append(MapCell(ix: ix, iz: iz, height: worldHeight(world) + verticalOffset, observations: 10, bestRange: 1.5))
            }
        }
        return GreenMapRecord(id: UUID(), courseName: "Test", holeNumber: 1, createdAt: Date(), cellSize: size,
                              edge: polygon.map { EdgePoint(x: $0.x, z: $0.y) }, cells: cells, coverage: 0.9,
                              qualityScore: quality, driftMillimetres: nil, trackingLossCount: 0, isPartial: false,
                              headingAligned: false, originLatitude: nil, originLongitude: nil)
    }

    func testAlignmentRecoversRotationAndShift() throws {
        let reference = syntheticScan(angle: 0, origin: .zero, verticalOffset: 0)
        let other = syntheticScan(angle: 40 * .pi / 180, origin: SIMD2(3, 2), verticalOffset: 0)
        let alignment = try XCTUnwrap(GreenAligner.align(source: other.edgeVector, sourceAligned: false,
                                                         target: reference.edgeVector, targetAligned: false))
        // Each L-shape vertex of the other scan must land on the matching world vertex.
        for (local, world) in zip(other.edgeVector, lShape) {
            XCTAssertLessThan(simd_distance(alignment.apply(local), world), 0.6)
        }
        XCTAssertGreaterThan(alignment.overlap, 0.85)
    }

    func testMergeCombinesTwoScansAndCorrectsHeightOffset() throws {
        // The second scan only saw the left part, so the merge must keep cells from both.
        let first = syntheticScan(angle: 0, origin: .zero, verticalOffset: 0, quality: 0.9) { $0.x > 3 }
        let second = syntheticScan(angle: 40 * .pi / 180, origin: SIMD2(3, 2), verticalOffset: 0.05, quality: 0.7) { $0.x < 9 }
        let result = try GreenMerger.merge([second, first])
        XCTAssertEqual(result.usedCount, 2)
        XCTAssertEqual(result.record.sourceScanCount, 2)
        let full = syntheticScan(angle: 0, origin: .zero, verticalOffset: 0)
        XCTAssertGreaterThan(result.record.cells.count, first.cells.count)
        XCTAssertGreaterThan(Double(result.record.cells.count), Double(full.cells.count) * 0.9)
        // Merged heights are in the best scan's frame, which here is the world frame.
        for cell in result.record.cells {
            let world = SIMD2<Float>((Float(cell.ix) + 0.5) * 0.2, (Float(cell.iz) + 0.5) * 0.2)
            XCTAssertEqual(cell.height, worldHeight(world), accuracy: 0.02)
        }
        XCTAssertFalse(GreenGeometry.selfIntersects(result.record.edgeVector))
        XCTAssertEqual(GreenGeometry.area(result.record.edgeVector), GreenGeometry.area(lShape), accuracy: GreenGeometry.area(lShape) * 0.1)
    }

    func testMergeRejectsNonOverlappingGreens() {
        let a = syntheticScan(angle: 0, origin: .zero, verticalOffset: 0)
        let squareOutline: [EdgePoint] = [EdgePoint(x: 0, z: 0), EdgePoint(x: 3, z: 0), EdgePoint(x: 3, z: 3), EdgePoint(x: 0, z: 3)]
        let b = GreenMapRecord(id: UUID(), courseName: "Test", holeNumber: 1, createdAt: Date(), cellSize: 0.2,
                               edge: squareOutline, cells: [MapCell(ix: 1, iz: 1, height: 0, observations: 5, bestRange: 1)],
                               coverage: 0.1, qualityScore: 0.1, driftMillimetres: nil, trackingLossCount: 0,
                               isPartial: true, headingAligned: false, originLatitude: nil, originLongitude: nil)
        XCTAssertThrowsError(try GreenMerger.merge([a, b]))
    }

    func testOutlineUnionOfOverlappingSquares() throws {
        let first: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(0, 4)]
        let second: [SIMD2<Float>] = [SIMD2(2, 0), SIMD2(6, 0), SIMD2(6, 4), SIMD2(2, 4)]
        let union = try XCTUnwrap(GreenOutline.union(polygons: [first, second], cellSize: 0.2))
        XCTAssertEqual(GreenGeometry.area(union.outline), 24, accuracy: 1.5)
        XCTAssertFalse(GreenGeometry.selfIntersects(union.outline))
        XCTAssertLessThan(union.outline.count, 12)
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
