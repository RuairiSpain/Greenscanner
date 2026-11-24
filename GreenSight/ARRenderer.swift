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

    // Materials are shared by all segments so the path does not allocate one per entity.
    private let fastMaterial = SimpleMaterial(color: .systemRed, isMetallic: false)
    private let mediumMaterial = SimpleMaterial(color: .systemOrange, isMetallic: false)
    private let slowMaterial = SimpleMaterial(color: .systemGreen, isMetallic: false)
    private let arrowMaterial = SimpleMaterial(color: .white, isMetallic: false)
    private let apexMaterial = SimpleMaterial(color: .systemPink, isMetallic: false)

    /// Draws the line coloured by pace (red fast, orange medium, green slow), a marker at the
    /// point of greatest sideways deviation (the apex of the break), and an aim arrow.
    func showTrajectory(_ solution: PuttSolution, surface: GreenSurface, basis: GreenBasis) {
        trajectoryEntities.forEach { $0.removeFromParent() }
        trajectoryEntities.removeAll()

        struct Node { let position: SIMD3<Float>; let speed: Float; let lateral: Float }
        let nodes: [Node] = solution.path.compactMap { point in
            let local = SIMD2<Double>(Double(point.x), Double(point.y))
            guard let height = surface.height(at: local) else { return nil }
            return Node(position: basis.world(x: point.x, along: point.y, height: Float(height) + 0.018),
                        speed: point.speed, lateral: abs(point.x))
        }
        guard nodes.count >= 2 else { return }

        let maxSpeed = max(Float(solution.launchSpeedMetresPerSecond), 0.1)
        var previous = nodes[0]
        for node in nodes.dropFirst() {
            // Merge short pieces so a long putt does not create hundreds of entities.
            guard simd_distance(previous.position, node.position) >= 0.05 || node.position == nodes.last?.position else { continue }
            let fraction = node.speed / maxSpeed
            let material = fraction > 0.66 ? fastMaterial : (fraction > 0.33 ? mediumMaterial : slowMaterial)
            addSegment(from: previous.position, to: node.position, radius: 0.008, material: material)
            previous = node
        }

        if let apex = nodes.max(by: { $0.lateral < $1.lateral }), apex.lateral > 0.03 {
            let marker = addSphere(at: apex.position + SIMD3<Float>(0, 0.03, 0), radius: 0.02, material: apexMaterial)
            trajectoryEntities.append(marker)
        }

        let arrowLength: Float = 0.35
        let angle = Float(solution.launchAngleDegrees * .pi / 180)
        let direction = basis.forward * cos(angle) + basis.right * sin(angle)
        let start = basis.origin + SIMD3<Float>(0, 0.025, 0)
        addSegment(from: start, to: start + direction * arrowLength, radius: 0.012, material: arrowMaterial)
    }

    @discardableResult
    private func addSphere(at position: SIMD3<Float>, radius: Float, color: UIColor) -> Entity {
        addSphere(at: position, radius: radius, material: SimpleMaterial(color: color, isMetallic: false))
    }

    @discardableResult
    private func addSphere(at position: SIMD3<Float>, radius: Float, material: SimpleMaterial) -> Entity {
        let entity = ModelEntity(mesh: .generateSphere(radius: radius), materials: [material])
        entity.position = position
        root?.addChild(entity)
        return entity
    }

    private func addSegment(from: SIMD3<Float>, to: SIMD3<Float>, radius: Float, material: SimpleMaterial) {
        let vector = to - from
        let length = simd_length(vector)
        guard length > 0.002 else { return }
        let entity = ModelEntity(mesh: .generateCylinder(height: length, radius: radius), materials: [material])
        entity.position = (from + to) * 0.5
        entity.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: vector / length)
        root?.addChild(entity)
        trajectoryEntities.append(entity)
    }
}
