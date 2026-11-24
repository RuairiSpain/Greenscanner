import Foundation
import RealityKit
import UIKit
import simd

@MainActor
final class ARRenderer {
    private weak var view: ARView?
    private var root: AnchorEntity?
    private var landmarks: [Entity] = []
    private var trajectoryEntities: [Entity] = []

    init(view: ARView) {
        self.view = view
        installRoot()
    }

    private func installRoot() {
        guard let view else { return }
        let anchor = AnchorEntity(world: SIMD3<Float>.zero)
        view.scene.addAnchor(anchor)
        root = anchor
    }

    func resetRoot() {
        root?.removeFromParent()
        landmarks.removeAll(keepingCapacity: true)
        trajectoryEntities.removeAll(keepingCapacity: true)
        installRoot()
    }

    func detach() {
        root?.removeFromParent()
        root = nil
        landmarks.removeAll()
        trajectoryEntities.removeAll()
        view = nil
    }

    func clear() {
        landmarks.forEach { $0.removeFromParent() }
        trajectoryEntities.forEach { $0.removeFromParent() }
        landmarks.removeAll()
        trajectoryEntities.removeAll()
    }

    func showLandmarks(ball: SIMD3<Float>?, cup: SIMD3<Float>?) {
        landmarks.forEach { $0.removeFromParent() }
        landmarks.removeAll()
        if let ball {
            landmarks.append(addSphere(at: ball + SIMD3<Float>(0, 0.025, 0), radius: 0.025, color: .white))
        }
        if let cup {
            let ring = ModelEntity(mesh: .generateCylinder(height: 0.006, radius: 0.055),
                                   materials: [SimpleMaterial(color: .systemTeal, isMetallic: false)])
            ring.position = cup + SIMD3<Float>(0, 0.008, 0)
            root?.addChild(ring)
            landmarks.append(ring)
        }
    }

    func showTrajectory(_ solution: PuttSolution, surface: GreenSurface, basis: GreenBasis) {
        trajectoryEntities.forEach { $0.removeFromParent() }
        trajectoryEntities.removeAll()
        let worldPoints: [SIMD3<Float>] = solution.path.compactMap { point in
            let local = SIMD2<Double>(Double(point.x), Double(point.y))
            guard let height = surface.height(at: local) else { return nil }
            return basis.world(x: point.x, along: point.y, height: Float(height) + 0.018)
        }
        guard worldPoints.count >= 2 else { return }
        let pathColor: UIColor = solution.holed ? .systemGreen : .systemOrange
        for index in 1..<worldPoints.count {
            addSegment(from: worldPoints[index - 1], to: worldPoints[index], radius: 0.008, color: pathColor)
        }

        let arrowLength: Float = 0.35
        let angle = Float(solution.launchAngleDegrees * .pi / 180)
        let direction = basis.forward * cos(angle) + basis.right * sin(angle)
        let start = basis.origin + SIMD3<Float>(0, 0.025, 0)
        addSegment(from: start, to: start + direction * arrowLength, radius: 0.012, color: .systemYellow)
    }

    @discardableResult
    private func addSphere(at position: SIMD3<Float>, radius: Float, color: UIColor) -> Entity {
        let entity = ModelEntity(mesh: .generateSphere(radius: radius),
                                 materials: [SimpleMaterial(color: color, isMetallic: false)])
        entity.position = position
        root?.addChild(entity)
        return entity
    }

    private func addSegment(from: SIMD3<Float>, to: SIMD3<Float>, radius: Float, color: UIColor) {
        let vector = to - from
        let length = simd_length(vector)
        guard length > 0.002 else { return }
        let entity = ModelEntity(mesh: .generateCylinder(height: length, radius: radius),
                                 materials: [SimpleMaterial(color: color, isMetallic: false)])
        entity.position = (from + to) * 0.5
        entity.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: vector / length)
        root?.addChild(entity)
        trajectoryEntities.append(entity)
    }
}
