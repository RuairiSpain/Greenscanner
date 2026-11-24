import Foundation
import SwiftUI
import ARKit
import RealityKit
import CoreLocation
import simd

/// State for "Map a Green" mode. Independent of the putt reader's AppModel.
enum MergeStatus {
    case working
    case failed(String)
    case ready(MergeResult)
}

final class MapModel: NSObject, ObservableObject, ARSessionDelegate {
    // Setup
    @Published var courseName = ""
    @Published var holeNumber = 1
    @Published var setupError: String?
    @Published var importError: String?
    @Published var records: [GreenMapRecord] = []
    @Published var mergeStatus: MergeStatus?

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
    @Published var residualMillimetres: Double?
    @Published var maxCorrectionMillimetres: Double?
    @Published var zoneGuidance = "Walk the inside and cover the grey areas on the map."
    @Published var zones: [ZoneStatus] = []
    @Published var coachMessage: String?
    @Published var draft: MapDraftHeader?
    @Published var draftBusy = false
    @Published var awaitingRelocalization = false
    @Published var recoveryMessage: String?
    @Published var depthSource: DepthSource {
        didSet { UserDefaults.standard.set(depthSource.rawValue, forKey: "greensight.depthSource") }
    }
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
    private var coach = MotionCoach()
    private let draftStore = DraftStore()
    private var pendingWorldMap: ARWorldMap?
    private var restoredHeadingAligned: Bool?
    private var lastCheckpoint: TimeInterval = 0
    private var checkpointInFlight = false
    private var draftGeneration = 0
    private var lastMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    private var lastCoachHaptic: TimeInterval = 0

    override init() {
        depthSource = DepthSource(rawValue: UserDefaults.standard.string(forKey: "greensight.depthSource") ?? "") ?? .raw
        super.init()
        location.onFirstFix = { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        let store = self.store
        let draftStore = self.draftStore
        persistenceQueue.async { [weak self] in
            let loaded = store.loadAll()
            let header = draftStore.loadHeader()
            DispatchQueue.main.async {
                self?.records = loaded
                self?.draft = header
            }
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

    /// Holes of a course that have more than one saved scan, with the scan counts.
    func mergeableHoles(course: String) -> [(hole: Int, count: Int)] {
        Dictionary(grouping: records.filter { $0.courseName == course }, by: \.holeNumber)
            .filter { $0.value.count >= 2 }
            .map { (hole: $0.key, count: $0.value.count) }
            .sorted { $0.hole < $1.hole }
    }

    @MainActor
    func startMerge(course: String, hole: Int) {
        let inputs = records.filter { $0.courseName == course && $0.holeNumber == hole }
        guard inputs.count >= 2 else { return }
        mergeStatus = .working
        processingQueue.async { [weak self] in
            let status: MergeStatus
            do {
                status = .ready(try GreenMerger.merge(inputs))
            } catch {
                status = .failed(error.localizedDescription)
            }
            DispatchQueue.main.async { self?.mergeStatus = status }
        }
    }

    @MainActor
    func dismissMerge() { mergeStatus = nil }

    @MainActor
    func saveMerged(_ result: MergeResult, removeSources: Bool) {
        records.insert(result.record, at: 0)
        let store = self.store
        let record = result.record
        let removed = removeSources ? (record.sourceIDs ?? []) : []
        if removeSources { records.removeAll { removed.contains($0.id) } }
        persistenceQueue.async {
            store.save(record)
            removed.forEach { store.delete($0) }
        }
        mergeStatus = nil
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
        guard draft == nil else {
            setupError = "Finish, save or discard the unfinished scan below before starting a new one."
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
        residualMillimetres = nil
        maxCorrectionMillimetres = nil
        zones = []
        coachMessage = nil
        coach.reset()
        zoneGuidance = "Walk the inside and cover the grey areas on the map."
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
        awaitingRelocalization = false
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
        if depthSource == .smoothed, ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .none
        if let map = pendingWorldMap {
            // Resuming a saved scan: relocalise against the saved map so its coordinates stay valid.
            configuration.initialWorldMap = map
            pendingWorldMap = nil
        }
        // Heading alignment puts +x east and +z south, which lets separate scans of one green be aligned later.
        if let aligned = restoredHeadingAligned {
            configuration.worldAlignment = aligned ? .gravityAndHeading : .gravity
            headingAligned = aligned
            restoredHeadingAligned = nil
        } else if location.canAlignToHeading {
            configuration.worldAlignment = .gravityAndHeading
            headingAligned = true
        } else {
            configuration.worldAlignment = .gravity
            headingAligned = false
        }
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        if !edgeWorld.isEmpty {
            renderer?.showEdge(edgeWorld, closed: phase != .edge)
            publishMinimap(polygon: localPolygon(), closed: phase != .edge, good: [], weak: [])
        }
    }

    @MainActor
    func endMapping(deletingDraft: Bool = true) {
        if deletingDraft { discardDraftFiles() }
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
            checkpoint(force: true, backgroundTask: true)
            view.session.pause()
            sessionPausedByUs = true
        } else if sessionPausedByUs {
            sessionPausedByUs = false
            let configuration = ARWorldTrackingConfiguration()
            configuration.frameSemantics.insert(.sceneDepth)
            if depthSource == .smoothed, ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            }
            configuration.worldAlignment = headingAligned ? .gravityAndHeading : .gravity
            view.session.run(configuration)
            if phase != .review { registerTrackingLoss() }
            accumulator.markDiscontinuity()
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
        checkpoint(force: false)
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
        checkpoint(force: true)
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
        let depthSourceName = depthSource.rawValue
        let coordinate = originCoordinate
        let currentScan = scanID
        processingQueue.async { [weak self] in
            let record = Self.buildRecord(accumulator: accumulator, edge: edge, name: name, hole: hole,
                                          losses: losses, aligned: aligned, coordinate: coordinate,
                                          depthSource: depthSourceName)
            DispatchQueue.main.async {
                guard let self, self.scanID == currentScan, self.phase == .review else { return }
                self.reviewRecord = record
            }
        }
    }

    static func buildRecord(accumulator: GreenMapAccumulator, edge: [EdgePoint], name: String, hole: Int,
                                        losses: Int, aligned: Bool, coordinate: CLLocationCoordinate2D?,
                                        depthSource: String) -> GreenMapRecord {
        let summary = accumulator.summary()
        let cells = accumulator.exportCells()
        let quality = MapQuality.score(coverage: summary.coverage, goodShare: summary.goodShare,
                                       driftMillimetres: summary.residualMillimetres ?? summary.driftMillimetres,
                                       trackingLosses: losses, unlinkedZones: summary.unlinkedZones)
        return GreenMapRecord(
            id: UUID(), courseName: name, holeNumber: hole, createdAt: Date(),
            cellSize: GreenMapAccumulator.cellSize, edge: edge, cells: cells,
            coverage: summary.coverage, qualityScore: quality,
            driftMillimetres: summary.driftMillimetres, trackingLossCount: losses,
            isPartial: summary.coverage < 0.85, headingAligned: aligned,
            originLatitude: coordinate?.latitude, originLongitude: coordinate?.longitude,
            zoneCount: summary.zones.count, residualMillimetres: summary.residualMillimetres,
            maxCorrectionMillimetres: summary.maxCorrectionMillimetres, unlinkedZones: summary.unlinkedZones,
            depthSource: depthSource, deviceModel: DeviceInfo.machine)
    }

    // MARK: Drafts (resumable scans)

    /// True when leaving now would lose real work.
    var hasUnsavedWork: Bool {
        (phase == .scanning && coverage > 0.05) || (phase == .edge && edgePointCount >= 3) || phase == .review
    }

    @MainActor
    private func discardDraftFiles() {
        draftGeneration += 1
        draft = nil
        let draftStore = self.draftStore
        persistenceQueue.async { draftStore.delete() }
    }

    @MainActor
    func discardDraft() { discardDraftFiles() }

    /// Writes the session to disk: edge points, scan data and, when ARKit can provide one, the world map
    /// that lets a restarted session relocalise into the same coordinates.
    @MainActor
    private func checkpoint(force: Bool, backgroundTask: Bool = false) {
        guard isMapping, !awaitingRelocalization, !edgeWorld.isEmpty else { return }
        let now = Date.timeIntervalSinceReferenceDate
        let interval: TimeInterval = phase == .edge ? 8 : 30
        guard force || now - lastCheckpoint >= interval else { return }
        guard !checkpointInFlight || now - lastCheckpoint > 60 else { return }
        lastCheckpoint = now
        checkpointInFlight = true

        let isScanning = phase != .edge
        let header = MapDraftHeader(courseName: courseName, holeNumber: holeNumber,
                                    phase: isScanning ? "scanning" : "edge", savedAt: Date(), coverage: coverage,
                                    edgePointCount: edgeWorld.count, hasScanData: isScanning, hasWorldMap: false)
        let basePayload = MapDraftPayload(edgeWorld: edgeWorld, origin: origin, headingAligned: headingAligned,
                                          originLatitude: originCoordinate?.latitude,
                                          originLongitude: originCoordinate?.longitude,
                                          trackingLossCount: trackingLossCount, depthSource: depthSource.rawValue,
                                          accumulator: nil)
        let accumulator = self.accumulator
        let draftStore = self.draftStore

        let taskBox = BackgroundTaskBox()
        if backgroundTask {
            taskBox.id = UIApplication.shared.beginBackgroundTask(withName: "greensight.checkpoint") {
                UIApplication.shared.endBackgroundTask(taskBox.id)
                taskBox.id = .invalid
            }
        }

        let generation = draftGeneration
        let write: (ARWorldMap?) -> Void = { [weak self] map in
            DispatchQueue.main.async {
                // The world map can arrive after the user has finished or discarded the scan; do not recreate the draft.
                guard let self, self.draftGeneration == generation else {
                    if taskBox.id != .invalid {
                        UIApplication.shared.endBackgroundTask(taskBox.id)
                        taskBox.id = .invalid
                    }
                    self?.checkpointInFlight = false
                    return
                }
                self.persistenceQueue.async {
                    var payload = basePayload
                    payload.accumulator = isScanning ? accumulator.snapshot() : nil
                    let mapData = map.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
                    let saved = draftStore.save(header: header, payload: payload, worldMapData: mapData)
                    DispatchQueue.main.async {
                        self.checkpointInFlight = false
                        if let saved, self.draftGeneration == generation { self.draft = saved }
                        if taskBox.id != .invalid {
                            UIApplication.shared.endBackgroundTask(taskBox.id)
                            taskBox.id = .invalid
                        }
                    }
                }
            }
        }

        if let view = arView, lastMappingStatus == .mapped || lastMappingStatus == .extending {
            view.session.getCurrentWorldMap { map, _ in write(map) }
        } else {
            write(nil)
        }
    }

    /// Continues a saved scan: restores the data, then relocalises against the saved world map.
    @MainActor
    func resumeDraft() {
        guard let header = draft, header.hasWorldMap, !draftBusy else { return }
        draftBusy = true
        let draftStore = self.draftStore
        persistenceQueue.async { [weak self] in
            let payload = draftStore.loadPayload()
            let mapData = draftStore.loadWorldMapData()
            let map = mapData.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.draftBusy = false
                guard let payload, let map else {
                    self.recoveryMessage = "The saved scan could not be loaded. You can still save what was captured."
                    return
                }
                self.courseName = header.courseName
                self.holeNumber = header.holeNumber
                self.resetMappingState()
                self.edgeWorld = payload.edgeWorld
                self.edgePointCount = payload.edgeWorld.count
                self.origin = payload.origin
                if let lat = payload.originLatitude, let lon = payload.originLongitude {
                    self.originCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
                self.trackingLossCount = payload.trackingLossCount
                self.restoredHeadingAligned = payload.headingAligned
                if let snapshot = payload.accumulator {
                    self.accumulator.restore(snapshot, scanID: self.scanID)
                    self.phase = .scanning
                    self.coverage = header.coverage
                } else {
                    self.phase = .edge
                }
                self.pendingWorldMap = map
                self.awaitingRelocalization = true
                self.lastWasNormal = false
                self.isMapping = true
            }
        }
    }

    /// Saves whatever a draft captured as a (partial) green without restarting the camera.
    @MainActor
    func recoverDraftAsGreen() {
        guard let header = draft, header.hasScanData, !draftBusy else { return }
        draftBusy = true
        let draftStore = self.draftStore
        let store = self.store
        persistenceQueue.async { [weak self] in
            guard let payload = draftStore.loadPayload(), let snapshot = payload.accumulator else {
                DispatchQueue.main.async {
                    self?.draftBusy = false
                    self?.recoveryMessage = "The saved scan data could not be read."
                }
                return
            }
            let recovered = GreenMapAccumulator()
            recovered.restore(snapshot, scanID: UUID())
            let edge = payload.edgeWorld.map { EdgePoint(x: $0.x - payload.origin.x, z: $0.z - payload.origin.z) }
            let coordinate: CLLocationCoordinate2D? = {
                guard let lat = payload.originLatitude, let lon = payload.originLongitude else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }()
            let record = Self.buildRecord(accumulator: recovered, edge: edge, name: header.courseName,
                                          hole: header.holeNumber, losses: payload.trackingLossCount,
                                          aligned: payload.headingAligned, coordinate: coordinate,
                                          depthSource: payload.depthSource)
            store.save(record)
            draftStore.delete()
            DispatchQueue.main.async {
                guard let self else { return }
                self.draftBusy = false
                self.draft = nil
                self.records.insert(record, at: 0)
                self.recoveryMessage = "Saved \(header.courseName) hole \(header.holeNumber) with "
                    + "\(record.coverage.formatted(.percent.precision(.fractionLength(0)))) coverage."
            }
        }
    }

    /// Leaves the camera view but keeps the saved draft, for example when relocalising does not succeed.
    @MainActor
    func leaveKeepingDraft() { endMapping(deletingDraft: false) }

    /// Gives up on relocalising and saves what the interrupted scan had captured.
    @MainActor
    func abandonRelocalizationAndSave() {
        endMapping(deletingDraft: false)
        recoverDraftAsGreen()
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
            if awaitingRelocalization { awaitingRelocalization = false }
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
        if lastWasNormal, phase != .review {
            trackingLossCount += 1
            accumulator.markDiscontinuity()
        }
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
        lastMappingStatus = frame.worldMappingStatus
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
            updateCoach(frame: frame)
            guard n.isMultiple(of: 3), !depthInFlight else { return }
            let id = scanID
            let timestamp = frame.timestamp
            let wantPublish = timestamp - lastPublish >= 1.0
            let accumulator = self.accumulator
            let smoothed = depthSource == .smoothed
            depthInFlight = true
            processingQueue.async { [weak self] in
                let output: (GreenMapAccumulator.Summary, [MapTile], [MapTile], [MapTile])? = autoreleasepool {
                    let samples = DepthProjector.project(frame: frame, stride: 3, smoothed: smoothed)
                    accumulator.ingest(samples, camera: camera, timestamp: timestamp, scanID: id)
                    guard wantPublish else { return nil }
                    let tiles = accumulator.tiles()
                    return (accumulator.summary(), tiles.good, tiles.weak, tiles.noisy)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.depthInFlight = false
                    guard self.scanID == id, self.phase == .scanning, let output else { return }
                    self.lastPublish = timestamp
                    self.apply(summary: output.0, good: output.1, weak: output.2, noisy: output.3)
                }
            }
        case .review:
            break
        }
    }

    @MainActor
    private func updateCoach(frame: ARFrame) {
        let advice = coach.update(transform: frame.camera.transform, timestamp: frame.timestamp)
        let message = advice?.message
        guard message != coachMessage else { return }
        coachMessage = message
        if message != nil, frame.timestamp - lastCoachHaptic > 5 {
            lastCoachHaptic = frame.timestamp
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    @MainActor
    private func apply(summary: GreenMapAccumulator.Summary, good: [MapTile], weak: [MapTile], noisy: [MapTile]) {
        coverage = summary.coverage
        driftMillimetres = summary.driftMillimetres
        residualMillimetres = summary.residualMillimetres
        maxCorrectionMillimetres = summary.maxCorrectionMillimetres
        zones = summary.zones
        let guidance = ZoneGuidance.message(zones: summary.zones, user: userPosition)
        zoneGuidance = guidance.text
        quality = MapQuality.score(coverage: summary.coverage, goodShare: summary.goodShare,
                                   driftMillimetres: summary.residualMillimetres ?? summary.driftMillimetres,
                                   trackingLosses: trackingLossCount, unlinkedZones: summary.unlinkedZones)
        renderer?.showCoverage(good: good, weak: weak, noisy: noisy, origin: origin)
        checkpoint(force: false)
        publishMinimap(polygon: localPolygon(), closed: true,
                       good: good.map { SIMD2<Float>($0.x, $0.z) }, weak: weak.map { SIMD2<Float>($0.x, $0.z) },
                       noisy: noisy.map { SIMD2<Float>($0.x, $0.z) }, zones: summary.zones, highlight: guidance.highlight)
    }

    @MainActor
    private func publishMinimap(polygon: [SIMD2<Float>], closed: Bool, good: [SIMD2<Float>], weak: [SIMD2<Float>],
                                noisy: [SIMD2<Float>] = [], zones: [ZoneStatus] = [], highlight: Int? = nil) {
        minimapVersion += 1
        minimap = MiniMapSnapshot(version: minimapVersion, polygon: polygon, closed: closed, good: good, weak: weak,
                                  noisy: noisy, zones: zones, highlightZone: highlight)
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

private final class BackgroundTaskBox: @unchecked Sendable {
    var id = UIBackgroundTaskIdentifier.invalid
}
