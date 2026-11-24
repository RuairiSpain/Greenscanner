import Foundation
import SwiftUI
import ARKit
import RealityKit
import CoreLocation
import simd

/// State for "Map a Green" mode. Independent of the putt reader's AppModel.
final class MapModel: NSObject, ObservableObject, ARSessionDelegate {
    // Setup
    @Published var courseName = ""
    @Published var holeNumber = 1
    @Published var setupError: String?
    @Published var importError: String?
    @Published var records: [GreenMapRecord] = []

    // Mapping
    @Published var isMapping = false
    @Published var phase: MapPhase = .edge
    @Published var trackingText = "Initialising"
    @Published var autoEdge = false
    @Published var edgePointCount = 0
    @Published var edgeProblem: String?
    @Published var coverage = 0.0
    @Published var quality = 0.0
    @Published var driftMillimetres: Double?
    @Published var trackingLossCount = 0
    @Published var minimap: MiniMapSnapshot = .empty
    @Published var userPosition: SIMD2<Float>?
    @Published var reviewRecord: GreenMapRecord?

    let location = LocationProvider()
    private weak var arView: ARView?
    private var renderer: MapRenderer?
    private let accumulator = GreenMapAccumulator()
    private let store = GreenMapStore()
    private let processingQueue = DispatchQueue(label: "greensight.map-processing", qos: .userInitiated)
    private let persistenceQueue = DispatchQueue(label: "greensight.map-persistence", qos: .utility)

    private var edgeWorld: [SIMD3<Float>] = []
    private var origin = SIMD3<Float>.zero
    private var originCoordinate: CLLocationCoordinate2D?
    private var headingAligned = false
    private var scanID = UUID()
    private var depthInFlight = false
    private var frameCounter = 0
    private var lastPublish: TimeInterval = 0
    private var lastWasNormal = true
    private var minimapVersion = 0
    private var scenePhaseActive = true
    private var sessionPausedByUs = false

    override init() {
        super.init()
        location.onFirstFix = { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        let store = self.store
        persistenceQueue.async { [weak self] in
            let loaded = store.loadAll()
            DispatchQueue.main.async { self?.records = loaded }
        }
    }

    // MARK: Saved greens

    var courseNames: [String] {
        Array(Set(records.map(\.courseName))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The saved course whose first green lies within 3 km of the current location.
    var nearbyCourseSuggestion: String? {
        guard let here = location.latest else { return nil }
        return records.compactMap { record -> (String, Double)? in
            guard let lat = record.originLatitude, let lon = record.originLongitude else { return nil }
            return (record.courseName, here.distance(from: CLLocation(latitude: lat, longitude: lon)))
        }
        .filter { $0.1 < 3000 }
        .min { $0.1 < $1.1 }?.0
    }

    func nextUnmappedHole(for course: String) -> Int {
        let mapped = Set(records.filter { $0.courseName == course }.map(\.holeNumber))
        return (1...18).first { !mapped.contains($0) } ?? 1
    }

    @MainActor
    func delete(_ ids: [UUID]) {
        records.removeAll { ids.contains($0.id) }
        let store = self.store
        persistenceQueue.async { ids.forEach { store.delete($0) } }
    }

    @MainActor
    func importGreen(from url: URL) {
        let store = self.store
        persistenceQueue.async { [weak self] in
            do {
                let record = try store.importRecord(from: url)
                store.save(record)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.records.contains(where: { $0.id == record.id }) {
                        self.importError = "That green is already saved."
                    } else {
                        self.records.insert(record, at: 0)
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.importError = error.localizedDescription }
            }
        }
    }

    func prepareExport(_ record: GreenMapRecord) async -> URL? {
        let store = self.store
        return await withCheckedContinuation { continuation in
            persistenceQueue.async { continuation.resume(returning: try? store.export(record)) }
        }
    }

    // MARK: Session lifecycle

    @MainActor
    func beginMapping() {
        let name = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            setupError = "Mapping needs a LiDAR iPhone or iPad."
            return
        }
        courseName = name
        setupError = nil
        resetMappingState()
        isMapping = true
    }

    @MainActor
    private func resetMappingState() {
        scanID = UUID()
        edgeWorld = []
        origin = .zero
        originCoordinate = nil
        edgePointCount = 0
        edgeProblem = nil
        coverage = 0
        quality = 0
        driftMillimetres = nil
        trackingLossCount = 0
        minimap = .empty
        userPosition = nil
        reviewRecord = nil
        phase = .edge
        depthInFlight = false
        frameCounter = 0
        lastPublish = 0
        lastWasNormal = true
        sessionPausedByUs = false
        trackingText = "Initialising"
    }

    @MainActor
    func attach(to view: ARView) {
        guard arView !== view else { return }
        renderer?.detach()
        arView?.session.delegate = nil
        arView = view
        renderer = MapRenderer(view: view)
        view.session.delegateQueue = .main
        view.session.delegate = self
        view.renderOptions.insert(.disableMotionBlur)

        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics.insert(.sceneDepth)
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .none
        // Heading alignment puts +x east and +z south, which lets separate scans of one green be aligned later.
        if location.canAlignToHeading {
            configuration.worldAlignment = .gravityAndHeading
            headingAligned = true
        } else {
            configuration.worldAlignment = .gravity
            headingAligned = false
        }
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    @MainActor
    func endMapping() {
        arView?.session.pause()
        arView?.session.delegate = nil
        renderer?.detach()
        renderer = nil
        arView = nil
        scanID = UUID()
        isMapping = false
        reviewRecord = nil
    }

    @MainActor
    func setSessionActive(_ active: Bool) {
        scenePhaseActive = active
        guard let view = arView else { return }
        if !active {
            guard !sessionPausedByUs else { return }
            view.session.pause()
            sessionPausedByUs = true
        } else if sessionPausedByUs {
            sessionPausedByUs = false
            let configuration = ARWorldTrackingConfiguration()
            configuration.frameSemantics.insert(.sceneDepth)
            configuration.worldAlignment = headingAligned ? .gravityAndHeading : .gravity
            view.session.run(configuration)
            if phase != .review { registerTrackingLoss() }
        }
    }

    // MARK: Edge

    @MainActor
    func handleTap(_ point: CGPoint) {
        guard phase == .edge, let view = arView else { return }
        guard let position = raycast(point, in: view) else {
            edgeProblem = "No surface found. Move slowly and try again."
            return
        }
        addEdgePoint(position)
    }

    @MainActor
    func addPointAtCentre() {
        guard phase == .edge, let view = arView else { return }
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let position = raycast(centre, in: view) else {
            edgeProblem = "No surface found. Aim at the ground and move slowly."
            return
        }
        addEdgePoint(position)
    }

    @MainActor
    private func addEdgePoint(_ position: SIMD3<Float>) {
        if edgeWorld.isEmpty {
            origin = position
            originCoordinate = location.latest?.coordinate
        }
        edgeWorld.append(position)
        edgePointCount = edgeWorld.count
        edgeProblem = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        refreshEdge()
    }

    @MainActor
    func undoEdgePoint() {
        guard phase == .edge, !edgeWorld.isEmpty else { return }
        edgeWorld.removeLast()
        edgePointCount = edgeWorld.count
        edgeProblem = nil
        if edgeWorld.isEmpty { originCoordinate = nil }
        refreshEdge()
    }

    @MainActor
    private func refreshEdge() {
        renderer?.showEdge(edgeWorld, closed: false)
        publishMinimap(polygon: localPolygon(), closed: false, good: [], weak: [])
    }

    private func localPolygon() -> [SIMD2<Float>] {
        edgeWorld.map { SIMD2<Float>($0.x - origin.x, $0.z - origin.z) }
    }

    @MainActor
    func closeShape() {
        guard phase == .edge else { return }
        let polygon = localPolygon()
        guard polygon.count >= 4 else { edgeProblem = "Add at least 4 edge points."; return }
        guard GreenGeometry.area(polygon) >= 4 else { edgeProblem = "The outline is too small to be a green."; return }
        guard !GreenGeometry.selfIntersects(polygon) else {
            edgeProblem = "The outline crosses itself. Undo points back to the crossing."
            return
        }
        edgeProblem = nil
        accumulator.configure(polygon: polygon, origin: origin, scanID: scanID)
        renderer?.showEdge(edgeWorld, closed: true)
        publishMinimap(polygon: polygon, closed: true, good: [], weak: [])
        phase = .scanning
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: Scanning and review

    @MainActor
    func finishScanning() {
        guard phase == .scanning else { return }
        phase = .review
        reviewRecord = nil
        let accumulator = self.accumulator
        let edge = localPolygon().map { EdgePoint(x: $0.x, z: $0.y) }
        let name = courseName, hole = holeNumber
        let losses = trackingLossCount
        let aligned = headingAligned
        let coordinate = originCoordinate
        let currentScan = scanID
        processingQueue.async { [weak self] in
            let summary = accumulator.summary()
            let cells = accumulator.exportCells()
            let quality = MapQuality.score(coverage: summary.coverage, goodShare: summary.goodShare,
                                           driftMillimetres: summary.driftMillimetres, trackingLosses: losses)
            let record = GreenMapRecord(
                id: UUID(), courseName: name, holeNumber: hole, createdAt: Date(),
                cellSize: GreenMapAccumulator.cellSize, edge: edge, cells: cells,
                coverage: summary.coverage, qualityScore: quality,
                driftMillimetres: summary.driftMillimetres, trackingLossCount: losses,
                isPartial: summary.coverage < 0.85, headingAligned: aligned,
                originLatitude: coordinate?.latitude, originLongitude: coordinate?.longitude)
            DispatchQueue.main.async {
                guard let self, self.scanID == currentScan, self.phase == .review else { return }
                self.reviewRecord = record
            }
        }
    }

    @MainActor
    func resumeScanning() {
        guard phase == .review else { return }
        reviewRecord = nil
        phase = .scanning
    }

    @MainActor
    func saveReviewedGreen() {
        guard let record = reviewRecord else { return }
        records.insert(record, at: 0)
        let store = self.store
        persistenceQueue.async { store.save(record) }
        endMapping()
    }

    // MARK: ARSessionDelegate

    @MainActor
    private func registerTrackingLoss() {
        guard phase != .review else { return }
        trackingLossCount += 1
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            trackingText = "Tracking stable"
            lastWasNormal = true
        case .notAvailable:
            trackingText = "Tracking unavailable"
            noteLoss()
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: trackingText = "Tracking limited: move more slowly"
            case .insufficientFeatures: trackingText = "Tracking limited: point at textured ground"
            case .relocalizing: trackingText = "Relocalising"
            default: trackingText = "Tracking limited"
            }
            noteLoss()
        @unknown default:
            trackingText = "Tracking changed"
        }
    }

    private func noteLoss() {
        if lastWasNormal, phase != .review { trackingLossCount += 1 }
        lastWasNormal = false
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let code = (error as? ARError)?.code
        trackingText = code == .cameraUnauthorized
            ? "Camera access denied. Enable it in Settings > GreenSight."
            : "AR session failed: \(error.localizedDescription)"
    }

    func sessionWasInterrupted(_ session: ARSession) {
        trackingText = "Session interrupted"
        noteLoss()
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        trackingText = "Interruption ended; hold steady"
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCounter += 1
        let n = frameCounter
        guard case .normal = frame.camera.trackingState else { return }
        let column = frame.camera.transform.columns.3
        let camera = SIMD3<Float>(column.x, column.y, column.z)

        if n.isMultiple(of: 10), !edgeWorld.isEmpty {
            userPosition = SIMD2<Float>(camera.x - origin.x, camera.z - origin.z)
        }

        switch phase {
        case .edge:
            guard autoEdge, n.isMultiple(of: 6), let view = arView, view.bounds.width > 0 else { return }
            let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            guard let position = raycast(centre, in: view) else { return }
            if let last = edgeWorld.last {
                let distance = simd_length(SIMD2<Float>(position.x - last.x, position.z - last.z))
                guard distance >= 2.0 else { return }
            }
            addEdgePoint(position)
        case .scanning:
            guard n.isMultiple(of: 3), !depthInFlight else { return }
            let id = scanID
            let timestamp = frame.timestamp
            let wantPublish = timestamp - lastPublish >= 1.0
            let accumulator = self.accumulator
            depthInFlight = true
            processingQueue.async { [weak self] in
                let output: (GreenMapAccumulator.Summary, [MapTile], [MapTile])? = autoreleasepool {
                    let samples = DepthProjector.project(frame: frame, stride: 3)
                    accumulator.ingest(samples, camera: camera, timestamp: timestamp, scanID: id)
                    guard wantPublish else { return nil }
                    let tiles = accumulator.tiles()
                    return (accumulator.summary(), tiles.good, tiles.weak)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.depthInFlight = false
                    guard self.scanID == id, self.phase == .scanning, let output else { return }
                    self.lastPublish = timestamp
                    self.apply(summary: output.0, good: output.1, weak: output.2)
                }
            }
        case .review:
            break
        }
    }

    @MainActor
    private func apply(summary: GreenMapAccumulator.Summary, good: [MapTile], weak: [MapTile]) {
        coverage = summary.coverage
        driftMillimetres = summary.driftMillimetres
        quality = MapQuality.score(coverage: summary.coverage, goodShare: summary.goodShare,
                                   driftMillimetres: summary.driftMillimetres, trackingLosses: trackingLossCount)
        renderer?.showCoverage(good: good, weak: weak, origin: origin)
        publishMinimap(polygon: localPolygon(), closed: true,
                       good: good.map { SIMD2<Float>($0.x, $0.z) }, weak: weak.map { SIMD2<Float>($0.x, $0.z) })
    }

    @MainActor
    private func publishMinimap(polygon: [SIMD2<Float>], closed: Bool, good: [SIMD2<Float>], weak: [SIMD2<Float>]) {
        minimapVersion += 1
        minimap = MiniMapSnapshot(version: minimapVersion, polygon: polygon, closed: closed, good: good, weak: weak)
    }

    @MainActor
    private func raycast(_ point: CGPoint, in view: ARView) -> SIMD3<Float>? {
        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            if let result = view.raycast(from: point, allowing: target, alignment: .any).first {
                let t = result.worldTransform.columns.3
                return SIMD3<Float>(t.x, t.y, t.z)
            }
        }
        return nil
    }
}
