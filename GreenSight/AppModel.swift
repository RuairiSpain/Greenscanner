import Foundation
import SwiftUI
import ARKit
import RealityKit
import Combine
import simd

final class AppModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var phase: ScanPhase = .idle
    @Published var trackingText = "Not started"
    @Published var coverage = 0.0
    @Published var stimpFeet = 10.0
    @Published var autoDetection = true
    @Published var showHeatMap = false
    @Published var showDiagnostics = false
    @Published var surface: HeightMapSnapshot = .empty
    @Published var solution: PuttSolution?
    @Published var records: [ScanRecord]
    @Published var exportURL: URL?

    private weak var arView: ARView?
    private var renderer: ARRenderer?
    private let accumulator = HeightMapAccumulator()
    private let detector = LandmarkDetector()
    private let store = ScanStore()
    private let processingQueue = DispatchQueue(label: "greensight.depth-processing", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "greensight.trajectory-analysis", qos: .userInitiated)
    private let persistenceQueue = DispatchQueue(label: "greensight.persistence", qos: .utility)
    private var frameCounter = 0
    private var ballPosition: SIMD3<Float>?
    private var cupPosition: SIMD3<Float>?
    private var scanID = UUID()
    private var analysisID = UUID()
    private var depthInFlightScanID: UUID?
    private var lastSurfacePublishTimestamp: TimeInterval = 0
    private var pendingCandidatePoint: CGPoint?
    private var pendingCandidateCount = 0

    override init() {
        records = []
        super.init()

        let store = self.store
        persistenceQueue.async { [weak self] in
            let loaded = store.load()
            DispatchQueue.main.async {
                guard let self else { return }
                var seen = Set<UUID>()
                self.records = (self.records + loaded)
                    .filter { seen.insert($0.id).inserted }
                    .sorted { $0.createdAt > $1.createdAt }
                if self.records.count > 25 { self.records = Array(self.records.prefix(25)) }
            }
        }
    }

    @MainActor
    func attach(to view: ARView) {
        guard arView !== view else { return }
        renderer?.detach()
        arView?.session.delegate = nil
        arView = view
        renderer = ARRenderer(view: view)
        view.session.delegateQueue = .main
        view.session.delegate = self
        view.renderOptions.insert(.disableMotionBlur)
    }

    @MainActor
    func startNewScan() {
        guard let view = arView else { return }
        scanID = UUID()
        analysisID = UUID()
        depthInFlightScanID = nil
        frameCounter = 0
        lastSurfacePublishTimestamp = 0
        resetCandidateTracking()
        ballPosition = nil
        cupPosition = nil
        solution = nil
        surface = .empty
        coverage = 0
        exportURL = nil

        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            renderer?.clear()
            phase = .unsupported("This device does not expose LiDAR scene depth. Use Demo to test the workflow.")
            return
        }

        view.session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        renderer?.resetRoot()
        phase = .markBall
        trackingText = "Initialising"
    }

    @MainActor
    func setSessionActive(_ active: Bool) {
        guard let view = arView else { return }
        if !active {
            view.session.pause()
            return
        }
        guard phase == .markBall || phase == .markCup || phase == .scanning || phase == .result else { return }
        view.session.run(makeConfiguration())
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.frameSemantics.insert(.sceneDepth)
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .none
        return configuration
    }

    @MainActor
    func handleTap(_ point: CGPoint) {
        guard let view = arView else { return }
        guard phase == .markBall || phase == .markCup else { return }
        guard let position = raycast(point, in: view) else {
            trackingText = "No surface found—move slowly and tap again"
            return
        }
        setLandmark(position)
    }

    @MainActor
    private func setLandmark(_ position: SIMD3<Float>) {
        resetCandidateTracking()
        switch phase {
        case .markBall:
            ballPosition = position
            phase = .markCup
        case .markCup:
            cupPosition = position
            guard let ballPosition, let cupPosition,
                  accumulator.reset(ball: ballPosition, cup: cupPosition, scanID: scanID) else {
                cupPosition = nil
                trackingText = "Ball and cup are too close"
                return
            }
            lastSurfacePublishTimestamp = 0
            phase = .scanning
        default:
            return
        }
        renderer?.showLandmarks(ball: ballPosition, cup: cupPosition)
    }

    private func resetCandidateTracking() {
        pendingCandidatePoint = nil
        pendingCandidateCount = 0
    }

    /// Accepts an automatic suggestion only after it has been seen at roughly the same screen
    /// position in several consecutive detections, so a single spurious contour cannot place a landmark.
    @MainActor
    private func confirmCandidate(at point: CGPoint) -> Bool {
        if let previous = pendingCandidatePoint, hypot(previous.x - point.x, previous.y - point.y) < 40 {
            pendingCandidateCount += 1
        } else {
            pendingCandidateCount = 1
        }
        pendingCandidatePoint = point
        return pendingCandidateCount >= 3
    }

    @MainActor
    private func raycast(_ point: CGPoint, in view: ARView) -> SIMD3<Float>? {
        let targets: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .estimatedPlane]
        for target in targets {
            if let result = view.raycast(from: point, allowing: target, alignment: .any).first {
                let t = result.worldTransform.columns.3
                return SIMD3<Float>(t.x, t.y, t.z)
            }
        }
        return nil
    }

    @MainActor
    func undoLandmark() {
        switch phase {
        case .markCup:
            resetCandidateTracking()
            ballPosition = nil
            phase = .markBall
        case .scanning:
            scanID = UUID()
            depthInFlightScanID = nil
            cupPosition = nil
            surface = .empty
            coverage = 0
            phase = .markCup
        default:
            return
        }
        renderer?.showLandmarks(ball: ballPosition, cup: cupPosition)
    }

    @MainActor
    func finishScan() {
        guard phase == .scanning, let ballPosition, let cupPosition else { return }
        let currentScanID = scanID
        guard surface.cells.count >= 30 else {
            trackingText = "Scan more of the putting corridor before calculating"
            return
        }

        phase = .processing
        let currentAnalysisID = UUID()
        analysisID = currentAnalysisID
        let stimp = stimpFeet
        let distance = Double(simd_length(SIMD2<Float>(cupPosition.x - ballPosition.x, cupPosition.z - ballPosition.z)))
        let accumulator = self.accumulator
        let analysisQueue = self.analysisQueue

        processingQueue.async {
            let snapshot = accumulator.snapshot(scanID: currentScanID)
            guard snapshot.cells.count >= 30 else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.analysisID == currentAnalysisID else { return }
                    self.phase = .scanning
                    self.trackingText = "Scan more of the putting corridor before calculating"
                }
                return
            }

            analysisQueue.async {
                let output: (GreenSurface, PuttSolution) = autoreleasepool {
                    let green = GreenSurface(snapshot: snapshot)
                    let physics = PuttingPhysics(surface: green, cup: SIMD2<Double>(0, distance), stimpFeet: stimp)
                    return (green, TrajectoryOptimizer(physics: physics).solve())
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.analysisID == currentAnalysisID,
                          self.scanID == currentScanID,
                          self.phase == .processing else { return }
                    let (green, result) = output
                    self.surface = snapshot
                    self.coverage = snapshot.coverage
                    self.solution = result
                    self.phase = .result
                    if let basis = accumulator.currentBasis(scanID: currentScanID) {
                        self.renderer?.showTrajectory(result, surface: green, basis: basis)
                    }
                    let record = ScanRecord(id: UUID(), createdAt: Date(), distanceMetres: distance,
                                            stimpFeet: stimp, coverage: snapshot.coverage,
                                            solution: result, surface: snapshot)
                    self.records.insert(record, at: 0)
                    if self.records.count > 25 { self.records = Array(self.records.prefix(25)) }
                    self.persist(records: self.records, exporting: record)
                }
            }
        }
    }

    @MainActor
    func runDemo() {
        scanID = UUID()
        depthInFlightScanID = nil
        arView?.session.pause()
        renderer?.clear()
        phase = .processing
        trackingText = "Building demo surface"
        solution = nil
        surface = .empty
        coverage = 0
        exportURL = nil

        let currentAnalysisID = UUID()
        analysisID = currentAnalysisID
        let stimp = stimpFeet
        analysisQueue.async {
            let output = autoreleasepool { DemoFactory.solution(stimpFeet: stimp) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.analysisID == currentAnalysisID, self.phase == .processing else { return }
                let (snapshot, result) = output
                self.surface = snapshot
                self.coverage = snapshot.coverage
                self.solution = result
                self.phase = .result
                self.trackingText = "Demo surface"
                let record = ScanRecord(id: UUID(), createdAt: Date(), distanceMetres: 3.2,
                                        stimpFeet: stimp, coverage: snapshot.coverage,
                                        solution: result, surface: snapshot)
                self.persistExport(record, analysisID: currentAnalysisID)
            }
        }
    }

    @MainActor
    func deleteRecords(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        persist(records: records)
    }

    private func persist(records: [ScanRecord], exporting record: ScanRecord? = nil) {
        let store = self.store
        persistenceQueue.async { [weak self] in
            store.save(records)
            let url = record.flatMap { try? store.export($0) }
            guard let record, let url else { return }
            DispatchQueue.main.async {
                guard let self, self.records.first?.id == record.id else { return }
                self.exportURL = url
            }
        }
    }

    private func persistExport(_ record: ScanRecord, analysisID: UUID) {
        let store = self.store
        persistenceQueue.async { [weak self] in
            let url = try? store.export(record)
            DispatchQueue.main.async {
                guard let self, self.analysisID == analysisID else { return }
                self.exportURL = url
            }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let text: String
        switch camera.trackingState {
        case .normal: text = "Tracking stable"
        case .notAvailable: text = "Tracking unavailable"
        case .limited(let reason): text = "Tracking limited: \(reason.description)"
        @unknown default: text = "Tracking changed"
        }
        trackingText = text
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let code = (error as? ARError)?.code
        switch code {
        case .cameraUnauthorized:
            trackingText = "Camera access denied. Enable it in Settings > GreenSight."
        case .unsupportedConfiguration, .sensorUnavailable:
            trackingText = "Required AR sensors are unavailable on this device."
        default:
            trackingText = "AR session failed: \(error.localizedDescription)"
        }
        if phase == .markBall || phase == .markCup || phase == .scanning {
            phase = .unsupported("AR session stopped. Tap Run interactive demo or restart the app.")
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        trackingText = "Session interrupted"
        // World tracking may be lost; measurements taken across an interruption are not reliable.
        if phase == .scanning { trackingText = "Interrupted. Restart the scan if tracking drifted." }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        trackingText = "Interruption ended; hold steady"
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCounter += 1
        let currentFrameNumber = frameCounter
        guard case .normal = frame.camera.trackingState else { return }
        let currentPhase = phase

        if autoDetection,
           (currentPhase == .markBall || currentPhase == .markCup),
           currentFrameNumber.isMultiple(of: 12),
           let view = arView,
           view.bounds.width > 0,
           view.bounds.height > 0 {
            let mode: DetectionMode = currentPhase == .markBall ? .ball : .cup
            let viewportSize = view.bounds.size
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            let displayTransform = frame.displayTransform(for: orientation, viewportSize: viewportSize)
            detector.detect(in: frame.capturedImage, mode: mode) { [weak self] candidate in
                guard let self, let candidate, candidate.confidence > 0.72 else { return }
                DispatchQueue.main.async {
                    guard self.phase == currentPhase, let view = self.arView else { return }
                    let imagePoint = CGPoint(x: candidate.normalizedCenter.x,
                                             y: 1 - candidate.normalizedCenter.y)
                        .applying(displayTransform)
                    let point = CGPoint(x: imagePoint.x * viewportSize.width,
                                        y: imagePoint.y * viewportSize.height)
                    guard self.confirmCandidate(at: point),
                          let position = self.raycast(point, in: view) else { return }
                    // The cup detector can re-detect the ball; never accept a cup on top of it.
                    if currentPhase == .markCup, let ball = self.ballPosition,
                       simd_distance(SIMD2<Float>(ball.x, ball.z), SIMD2<Float>(position.x, position.z)) < 0.3 {
                        self.resetCandidateTracking()
                        return
                    }
                    self.setLandmark(position)
                }
            }
        }

        guard currentPhase == .scanning,
              currentFrameNumber.isMultiple(of: 3),
              depthInFlightScanID == nil else { return }

        let currentScanID = scanID
        let shouldPublish = frame.timestamp - lastSurfacePublishTimestamp >= 0.75
        depthInFlightScanID = currentScanID
        let accumulator = self.accumulator
        processingQueue.async {
            let snapshot: HeightMapSnapshot? = autoreleasepool {
                let samples = DepthProjector.project(frame: frame)
                accumulator.ingest(samples, scanID: currentScanID)
                return shouldPublish ? accumulator.snapshot(scanID: currentScanID) : nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.depthInFlightScanID == currentScanID { self.depthInFlightScanID = nil }
                guard self.scanID == currentScanID, self.phase == .scanning else { return }
                if let snapshot, !snapshot.cells.isEmpty {
                    self.lastSurfacePublishTimestamp = frame.timestamp
                    self.surface = snapshot
                    self.coverage = snapshot.coverage
                }
            }
        }
    }
}

private extension ARCamera.TrackingState.Reason {
    var description: String {
        switch self {
        case .initializing: return "initialising"
        case .excessiveMotion: return "move more slowly"
        case .insufficientFeatures: return "point at textured ground"
        case .relocalizing: return "relocalising"
        @unknown default: return "unknown"
        }
    }
}
