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

    // MARK: Walking guide

    private let wideGreen: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(14, 0), SIMD2(14, 6), SIMD2(0, 6)]

    func testAcrossRouteCoversGreenInLanes() {
        let plan = WalkPlanner.plan(mode: .acrossGreen, polygon: wideGreen, cup: nil, start: nil)
        XCTAssertEqual(plan.mode, .acrossGreen)
        XCTAssertGreaterThanOrEqual(plan.reachableFraction, 0.95)
        // Two lanes about 13 m long plus the connection between them.
        XCTAssertEqual(plan.lengthMetres, 29.4, accuracy: 3)
        for point in plan.path { XCTAssertTrue(GreenGeometry.contains(wideGreen, point: point)) }
        XCTAssertLessThanOrEqual(zip(plan.waypoints, plan.waypoints.dropFirst()).map { simd_distance($0, $1) }.max() ?? 0,
                                 WalkPlanner.waypointSpacing + 0.01)
    }

    func testRouteStartsNearestTheWalker() {
        let plan = WalkPlanner.plan(mode: .acrossGreen, polygon: wideGreen, cup: nil, start: SIMD2<Float>(13.5, 5.5))
        XCTAssertLessThan(simd_distance(plan.path[0], SIMD2<Float>(13.5, 5.5)), 2)
    }

    func testRouteKeepsOutOfCupSurround() {
        let cup = SIMD2<Float>(7, 1.5)
        let plan = WalkPlanner.plan(mode: .acrossGreen, polygon: wideGreen, cup: cup, start: nil)
        for point in WalkPlanner.resample(plan.path, spacing: 0.25) {
            XCTAssertGreaterThanOrEqual(simd_distance(point, cup), WalkPlanner.cupKeepOut - 0.05)
        }
        XCTAssertGreaterThanOrEqual(plan.reachableFraction, 0.9)
    }

    func testFringeRouteStaysOffTheGreen() {
        let big: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(14, 0), SIMD2(14, 10), SIMD2(0, 10)]
        let plan = WalkPlanner.plan(mode: .fringeOnly, polygon: big, cup: nil, start: nil)
        XCTAssertEqual(plan.mode, .fringeOnly)
        XCTAssertGreaterThan(plan.path.count, 4)
        for point in plan.path { XCTAssertFalse(GreenGeometry.contains(big, point: point)) }
        // A path about 1 m outside a 14 x 10 m green reaches the outer band only.
        XCTAssertGreaterThan(plan.reachableFraction, 0.4)
        XCTAssertLessThan(plan.reachableFraction, 0.8)
        XCTAssertEqual(plan.path.first, plan.path.last)
    }

    func testWalkModeOffGivesEmptyPlan() {
        XCTAssertTrue(WalkPlanner.plan(mode: .off, polygon: wideGreen, cup: nil, start: nil).path.isEmpty)
    }

    func testResampleKeepsCornersAndSpacing() {
        let path: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(5, 0), SIMD2(5, 3)]
        let out = WalkPlanner.resample(path, spacing: 2)
        XCTAssertTrue(out.contains(SIMD2<Float>(5, 0)))
        XCTAssertEqual(out.last, SIMD2<Float>(5, 3))
    }

    // MARK: Resumable scans

    func testAccumulatorSnapshotRestoresScan() throws {
        let original = GreenMapAccumulator()
        let id = UUID()
        original.configure(polygon: longGreen, origin: SIMD3<Float>(1, 2, 3), scanID: id)
        for step in 0..<4 {
            original.ingest(block(x: 1.01...9, z: 3.01...8.99, height: 2), camera: SIMD3<Float>(4, 3.5, 6),
                            timestamp: Double(step), scanID: id)
        }
        let snapshot = try XCTUnwrap(original.snapshot())
        let plist = PropertyListEncoder(); plist.outputFormat = .binary
        let decoded = try PropertyListDecoder().decode(GreenMapAccumulator.Snapshot.self, from: plist.encode(snapshot))

        let restored = GreenMapAccumulator()
        restored.restore(decoded, scanID: UUID())
        let before = original.summary(), after = restored.summary()
        XCTAssertEqual(after.good + after.weak + after.noisy, before.good + before.weak + before.noisy)
        XCTAssertEqual(after.total, before.total)
        let a = original.exportCells(smooth: false), b = restored.exportCells(smooth: false)
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a.first?.height ?? 0, b.first?.height ?? 1, accuracy: 1e-6)
    }

    func testRestoredScanTiesNewDataToSavedDataAfterDrift() throws {
        let original = GreenMapAccumulator()
        let id = UUID()
        original.configure(polygon: longGreen, origin: .zero, scanID: id)
        for step in 0..<4 {
            original.ingest(block(x: 0.01...8, z: 0.01...5.99, height: 0), camera: SIMD3<Float>(3, 1.5, 3),
                            timestamp: Double(step), scanID: id)
        }
        // After a restart, relocalisation is off by 0.02 m vertically; the shared area must pull it back.
        let restored = GreenMapAccumulator()
        let newID = UUID()
        restored.restore(try XCTUnwrap(original.snapshot()), scanID: newID)
        for step in 0..<4 {
            restored.ingest(block(x: 4.01...13.99, z: 0.01...5.99, height: 0.02), camera: SIMD3<Float>(9, 1.5, 3),
                            timestamp: 100 + Double(step), scanID: newID)
        }
        for cell in restored.exportCells(smooth: false) {
            XCTAssertEqual(cell.height, 0, accuracy: 0.004)
        }
    }

    func testDraftStoreRoundTripAndDelete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("draft-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DraftStore(directory: directory)
        XCTAssertNil(store.loadHeader())

        let header = MapDraftHeader(courseName: "Links", holeNumber: 4, phase: "scanning", savedAt: Date(),
                                    coverage: 0.5, edgePointCount: 6, hasScanData: true, hasWorldMap: false)
        let payload = MapDraftPayload(edgeWorld: [SIMD3<Float>(1, 0, 2), SIMD3<Float>(3, 0, 4)], origin: SIMD3<Float>(1, 0, 2),
                                      headingAligned: true, originLatitude: 53.3, originLongitude: -6.2,
                                      trackingLossCount: 2, depthSource: "raw", accumulator: nil)
        let saved = try XCTUnwrap(store.save(header: header, payload: payload, worldMapData: Data([1, 2, 3])))
        XCTAssertTrue(saved.hasWorldMap)
        XCTAssertEqual(store.loadHeader()?.courseName, "Links")
        XCTAssertEqual(store.loadPayload()?.edgeWorld.count, 2)
        XCTAssertEqual(store.loadWorldMapData(), Data([1, 2, 3]))

        // A later save without a new world map keeps the old one.
        let again = try XCTUnwrap(store.save(header: header, payload: payload, worldMapData: nil))
        XCTAssertTrue(again.hasWorldMap)

        store.delete()
        XCTAssertNil(store.loadHeader())
        XCTAssertNil(store.loadPayload())
    }

    // MARK: Scan quality

    private func cameraPose(position: SIMD3<Float>, forward: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(forward)
        let z = -f
        var x = simd_cross(SIMD3<Float>(0, 1, 0), z)
        if simd_length(x) < 1e-4 { x = SIMD3<Float>(1, 0, 0) }
        x = simd_normalize(x)
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4<Float>(x, 0), SIMD4<Float>(y, 0), SIMD4<Float>(z, 0), SIMD4<Float>(position, 1)))
    }

    func testIncidenceWeightFavoursSteepViews() {
        XCTAssertEqual(DepthProjector.incidenceWeight(rayY: -1), 1, accuracy: 1e-6)
        XCTAssertGreaterThan(DepthProjector.incidenceWeight(rayY: -0.9), DepthProjector.incidenceWeight(rayY: -0.3))
        XCTAssertEqual(DepthProjector.incidenceWeight(rayY: -0.01), 0.2, accuracy: 1e-6)
    }

    func testCoachStaysQuietWhenScanningWell() {
        var coach = MotionCoach()
        for frame in 0..<40 {
            coach.update(transform: cameraPose(position: SIMD3<Float>(Float(frame) * 0.01, 1.5, 0),
                                               forward: SIMD3<Float>(0, -0.6, -0.8)), timestamp: Double(frame) / 30)
        }
        XCTAssertNil(coach.advice)
    }

    func testCoachFlagsFastWalking() {
        var coach = MotionCoach()
        for frame in 0..<40 {
            coach.update(transform: cameraPose(position: SIMD3<Float>(Float(frame) * 0.1, 1.5, 0),
                                               forward: SIMD3<Float>(0, -0.6, -0.8)), timestamp: Double(frame) / 30)
        }
        XCTAssertEqual(coach.advice, .slowDown)
    }

    func testCoachFlagsFastTurningAndShallowTilt() {
        var turning = MotionCoach()
        for frame in 0..<40 {
            let yaw = Float(frame) * 5 * .pi / 180
            turning.update(transform: cameraPose(position: SIMD3<Float>(0, 1.5, 0),
                                                 forward: SIMD3<Float>(sin(yaw), -0.6, -cos(yaw))), timestamp: Double(frame) / 30)
        }
        XCTAssertEqual(turning.advice, .turningTooFast)

        var level = MotionCoach()
        for frame in 0..<40 {
            level.update(transform: cameraPose(position: SIMD3<Float>(0, 1.5, 0),
                                               forward: SIMD3<Float>(0, -0.1, -1)), timestamp: Double(frame) / 30)
        }
        XCTAssertEqual(level.advice, .tiltDown)
    }

    func testSteadyCellsAreGoodAndJitteryCellsAreNoisy() {
        let steady = GreenMapAccumulator()
        let jittery = GreenMapAccumulator()
        let id = UUID()
        steady.configure(polygon: square, origin: .zero, scanID: id)
        jittery.configure(polygon: square, origin: .zero, scanID: id)
        for step in 0..<4 {
            steady.ingest(flatSamples(), camera: SIMD3<Float>(2, 1.5, 2), timestamp: Double(step), scanID: id)
            jittery.ingest(flatSamples(height: step.isMultiple(of: 2) ? 0.02 : -0.02),
                           camera: SIMD3<Float>(2, 1.5, 2), timestamp: Double(step), scanID: id)
        }
        let steadySummary = steady.summary()
        let jitterSummary = jittery.summary()
        XCTAssertEqual(steadySummary.noisy, 0)
        XCTAssertGreaterThan(steadySummary.good, 300)
        XCTAssertGreaterThan(jitterSummary.noisy, 300)
        XCTAssertEqual(jitterSummary.good, 0)
        let noise = jittery.exportCells(smooth: false).first?.noise ?? 0
        XCTAssertEqual(noise, 0.02, accuracy: 0.003)
    }

    private func noisyPlane(noise: Float) -> [MapCell] {
        var cells: [MapCell] = []
        for ix in 0..<30 {
            for iz in 0..<30 {
                let jitter = noise * Float(sin(Double(ix * 7 + iz * 13) * 12.9898) )
                cells.append(MapCell(ix: ix, iz: iz, height: 0.02 * (Float(ix) + 0.5) * 0.2 + jitter,
                                     observations: 10, bestRange: 1.5, noise: 0.003))
            }
        }
        return cells
    }

    func testSmootherReducesNoiseAndKeepsSlope() {
        let cells = noisyPlane(noise: 0.004)
        let smoothed = SurfaceSmoother.smooth(cells: cells, cellSize: 0.2)
        func rms(_ heights: [Float]) -> Float {
            var sum: Float = 0
            for (cell, h) in zip(cells, heights) {
                let truth = 0.02 * (Float(cell.ix) + 0.5) * 0.2
                sum += (h - truth) * (h - truth)
            }
            return (sum / Float(cells.count)).squareRoot()
        }
        XCTAssertLessThan(rms(smoothed), rms(cells.map(\.height)) * 0.6)
        let grades = MapSlope.grades(cells: zip(cells, smoothed).map {
            MapCell(ix: $0.ix, iz: $0.iz, height: $1, observations: 10, bestRange: 1.5)
        }, cellSize: 0.2)
        XCTAssertEqual(grades[15 * 30 + 15], 0.02, accuracy: 0.004)
    }

    func testSmootherRejectsIsolatedSpike() {
        var cells: [MapCell] = []
        for ix in 0..<15 {
            for iz in 0..<15 {
                let spike: Float = (ix == 7 && iz == 7) ? 0.05 : 0
                cells.append(MapCell(ix: ix, iz: iz, height: spike, observations: 10, bestRange: 1.5))
            }
        }
        let smoothed = SurfaceSmoother.smooth(cells: cells, cellSize: 0.2)
        XCTAssertEqual(smoothed[7 * 15 + 7], 0, accuracy: 0.005)
    }

    func testCellNoiseRoundTripsAndOldFilesStillDecode() throws {
        let cell = MapCell(ix: 1, iz: 2, height: 0.1, observations: 5, bestRange: 1.2, noise: 0.004)
        let decoded = try JSONDecoder().decode(MapCell.self, from: JSONEncoder().encode(cell))
        XCTAssertEqual(decoded.noise ?? 0, 0.004, accuracy: 1e-7)
        let old = try JSONDecoder().decode(MapCell.self, from: Data("[1,2,0.1,5,1.2]".utf8))
        XCTAssertNil(old.noise)
        XCTAssertEqual(old.iz, 2)
    }

    private func recordFrom(cells: [MapCell]) -> GreenMapRecord {
        GreenMapRecord(id: UUID(), courseName: "Validation", holeNumber: 1, createdAt: Date(), cellSize: 0.2,
                       edge: square.map { EdgePoint(x: $0.x, z: $0.y) }, cells: cells, coverage: 1, qualityScore: 1,
                       driftMillimetres: nil, trackingLossCount: 0, isPartial: false, headingAligned: false,
                       originLatitude: nil, originLongitude: nil)
    }

    func testValidationRecoversKnownGradeAndReportsSlopeNoise() throws {
        let report = try XCTUnwrap(ValidationReport.make(from: recordFrom(cells: noisyPlane(noise: 0.002)),
                                                         expectedGradePercent: 2))
        XCTAssertEqual(report.planeGradePercent, 2, accuracy: 0.15)
        XCTAssertLessThan(abs(report.gradeErrorPercent ?? 99), 0.15)
        XCTAssertLessThan(report.rmsResidualMillimetres, 4)
        XCTAssertLessThan(report.localGradeErrorMedianPercent ?? 99, 1.5)
        XCTAssertFalse(report.buckets.isEmpty)
        XCTAssertTrue(report.json.contains("planeGradePercent"))
    }

    func testValidationReportRequiresEnoughCells() {
        XCTAssertNil(ValidationReport.make(from: recordFrom(cells: Array(noisyPlane(noise: 0).prefix(10))), expectedGradePercent: 0))
    }

    // MARK: Zones and height correction

    private func block(x: ClosedRange<Float>, z: ClosedRange<Float>, height: Float) -> [WorldSample] {
        var samples: [WorldSample] = []
        var px = x.lowerBound
        while px <= x.upperBound {
            var pz = z.lowerBound
            while pz <= z.upperBound {
                samples.append(WorldSample(position: SIMD3<Float>(px, height, pz), weight: 1))
                pz += 0.05
            }
            px += 0.05
        }
        return samples
    }

    private let longGreen: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(14, 0), SIMD2(14, 6), SIMD2(0, 6)]

    func testPartitionSplitsLongShapeIntoCompactZones() {
        var points: [SIMD2<Float>] = []
        for x in 0..<70 { for z in 0..<30 { points.append(SIMD2(Float(x) * 0.2 + 0.1, Float(z) * 0.2 + 0.1)) } }
        let result = GreenMapAccumulator.partition(points: points, clusters: 2)
        XCTAssertEqual(Set(result.assignment).count, 2)
        let xs = result.centres.map(\.x).sorted()
        XCTAssertLessThan(xs[0], 5)
        XCTAssertGreaterThan(xs[1], 9)
    }

    func testLinearSolverSolvesSmallSystem() throws {
        let x = try XCTUnwrap(GreenMapAccumulator.solveLinear([2, 1, 1, 3], [5, 10], n: 2))
        XCTAssertEqual(x[0], 1, accuracy: 1e-9)
        XCTAssertEqual(x[1], 3, accuracy: 1e-9)
    }

    func testZonePassesAreTiedTogetherAndDriftIsCorrected() {
        let accumulator = GreenMapAccumulator()
        let id = UUID()
        accumulator.configure(polygon: longGreen, origin: .zero, scanID: id)
        // Pass 1 stands in the left zone; pass 2 stands in the right zone after 0.03 m of drift.
        // The two passes both see x in 6...8, which links them.
        for step in 0..<4 {
            accumulator.ingest(block(x: 0.01...8, z: 0.01...5.99, height: 0), camera: SIMD3<Float>(3, 1.5, 3),
                               timestamp: Double(step), scanID: id)
        }
        for step in 0..<4 {
            accumulator.ingest(block(x: 6.01...13.99, z: 0.01...5.99, height: 0.03), camera: SIMD3<Float>(11, 1.5, 3),
                               timestamp: 5 + Double(step), scanID: id)
        }
        let summary = accumulator.summary()
        XCTAssertEqual(summary.zones.count, 2)
        XCTAssertEqual(summary.unlinkedZones, 0)
        XCTAssertEqual(summary.driftMillimetres ?? 0, 30, accuracy: 3)
        XCTAssertLessThan(summary.residualMillimetres ?? 99, 3)
        XCTAssertEqual(summary.maxCorrectionMillimetres ?? 0, 30, accuracy: 3)
        for cell in accumulator.exportCells() {
            XCTAssertEqual(cell.height, 0, accuracy: 0.004)
        }
    }

    func testZoneWithoutOverlapIsReportedUnlinked() {
        let accumulator = GreenMapAccumulator()
        let id = UUID()
        accumulator.configure(polygon: longGreen, origin: .zero, scanID: id)
        for step in 0..<4 {
            accumulator.ingest(block(x: 0.01...5, z: 0.01...5.99, height: 0), camera: SIMD3<Float>(3, 1.5, 3),
                               timestamp: Double(step), scanID: id)
        }
        for step in 0..<4 {
            accumulator.ingest(block(x: 9.01...13.99, z: 0.01...5.99, height: 0.03), camera: SIMD3<Float>(11, 1.5, 3),
                               timestamp: 5 + Double(step), scanID: id)
        }
        let summary = accumulator.summary()
        XCTAssertEqual(summary.unlinkedZones, 1)
        let guidance = ZoneGuidance.message(zones: summary.zones, user: SIMD2<Float>(11, 3))
        XCTAssertNotNil(guidance.highlight)
        XCTAssertTrue(guidance.text.contains("not linked"))
    }

    func testDiscontinuityStartsNewEpochSoJumpIsCorrected() {
        let accumulator = GreenMapAccumulator()
        let id = UUID()
        accumulator.configure(polygon: square, origin: .zero, scanID: id)
        for step in 0..<4 {
            accumulator.ingest(flatSamples(), camera: SIMD3<Float>(2, 1.5, 2), timestamp: Double(step), scanID: id)
        }
        accumulator.markDiscontinuity()
        for step in 0..<4 {
            accumulator.ingest(flatSamples(height: 0.03), camera: SIMD3<Float>(2, 1.5, 2), timestamp: 5 + Double(step), scanID: id)
        }
        for cell in accumulator.exportCells() {
            XCTAssertEqual(cell.height, 0, accuracy: 0.004)
        }
    }

    func testGuidanceDirectsToNextZone() {
        let zones = [
            ZoneStatus(index: 0, centre: SIMD2(2, 3), cellCount: 100, coveredCount: 100, state: .complete, linked: true),
            ZoneStatus(index: 1, centre: SIMD2(8, 3), cellCount: 100, coveredCount: 0, state: .notStarted, linked: false)
        ]
        let guidance = ZoneGuidance.message(zones: zones, user: SIMD2(3, 3))
        XCTAssertEqual(guidance.highlight, 1)
        XCTAssertTrue(guidance.text.contains("zone 2"))
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
