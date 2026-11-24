import Foundation
import RealityKit
import UIKit
import simd

/// Draws the green edge and the scanned-coverage overlay for the mapping mode.
@MainActor
final class MapRenderer {
    private weak var view: ARView?
    private var root: AnchorEntity?
    private var edgeEntities: [Entity] = []
    private var goodEntity: ModelEntity?
    private var weakEntity: ModelEntity?
    private var noisyEntity: ModelEntity?
    private var walkEntity: ModelEntity?
    private var walkMarker: ModelEntity?
    private var cupEntity: ModelEntity?
    private var startEntity: ModelEntity?
    private var recoveryEntity: ModelEntity?

    private let edgeMaterial = SimpleMaterial(color: .white, isMetallic: false)
    private let pointMaterial = SimpleMaterial(color: .systemMint, isMetallic: false)
    private let goodMaterial = SimpleMaterial(color: UIColor.systemGreen.withAlphaComponent(0.55), isMetallic: false)
    private let weakMaterial = SimpleMaterial(color: UIColor.systemOrange.withAlphaComponent(0.55), isMetallic: false)
    private let walkMaterial = SimpleMaterial(color: UIColor.systemCyan.withAlphaComponent(0.8), isMetallic: false)
    private let markerMaterial = SimpleMaterial(color: UIColor.systemCyan, isMetallic: false)
    private let keepOutMaterial = SimpleMaterial(color: UIColor.systemRed.withAlphaComponent(0.4), isMetallic: false)
    private let noisyMaterial = SimpleMaterial(color: UIColor.systemRed.withAlphaComponent(0.6), isMetallic: false)

    init(view: ARView) {
        self.view = view
        let anchor = AnchorEntity(world: SIMD3<Float>.zero)
        view.scene.addAnchor(anchor)
        root = anchor
    }

    func detach() {
        root?.removeFromParent()
        root = nil
        edgeEntities.removeAll()
        goodEntity = nil
        weakEntity = nil
        noisyEntity = nil
        walkEntity = nil
        walkMarker = nil
        cupEntity = nil
        startEntity = nil
        recoveryEntity = nil
        view = nil
    }

    func showEdge(_ points: [SIMD3<Float>], closed: Bool) {
        edgeEntities.forEach { $0.removeFromParent() }
        edgeEntities.removeAll()
        for point in points {
            let sphere = ModelEntity(mesh: .generateSphere(radius: 0.04), materials: [pointMaterial])
            sphere.position = point + SIMD3<Float>(0, 0.03, 0)
            root?.addChild(sphere)
            edgeEntities.append(sphere)
        }
        guard points.count >= 2 else { return }
        for index in 1..<points.count {
            addSegment(from: points[index - 1], to: points[index])
        }
        if closed, let first = points.first, let last = points.last {
            addSegment(from: last, to: first)
        }
    }

    private func addSegment(from: SIMD3<Float>, to: SIMD3<Float>) {
        let a = from + SIMD3<Float>(0, 0.03, 0)
        let b = to + SIMD3<Float>(0, 0.03, 0)
        let vector = b - a
        let length = simd_length(vector)
        guard length > 0.01 else { return }
        let entity = ModelEntity(mesh: .generateCylinder(height: length, radius: 0.012), materials: [edgeMaterial])
        entity.position = (a + b) * 0.5
        entity.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: vector / length)
        root?.addChild(entity)
        edgeEntities.append(entity)
    }

    /// Replaces the coverage overlay. Tiles are in map-local metres; `origin` converts them to world space.
    func showCoverage(good: [MapTile], weak: [MapTile], noisy: [MapTile], origin: SIMD3<Float>) {
        goodEntity = update(goodEntity, tiles: good, origin: origin, material: goodMaterial)
        weakEntity = update(weakEntity, tiles: weak, origin: origin, material: weakMaterial)
        noisyEntity = update(noisyEntity, tiles: noisy, origin: origin, material: noisyMaterial)
    }

    /// Draws the planned route as a flat ribbon with a tall marker at the next waypoint.
    func showWalkRoute(_ points: [SIMD3<Float>]) {
        walkMarker?.removeFromParent()
        walkMarker = nil
        guard points.count >= 2, let mesh = makeRibbon(points, width: 0.14) else {
            walkEntity?.removeFromParent()
            walkEntity = nil
            return
        }
        if let walkEntity {
            walkEntity.model?.mesh = mesh
        } else {
            let entity = ModelEntity(mesh: mesh, materials: [walkMaterial])
            root?.addChild(entity)
            walkEntity = entity
        }
        let marker = ModelEntity(mesh: .generateCylinder(height: 0.8, radius: 0.03), materials: [markerMaterial])
        marker.position = points[0] + SIMD3<Float>(0, 0.4, 0)
        root?.addChild(marker)
        walkMarker = marker
    }

    func clearWalkRoute() { showWalkRoute([]) }

    /// Blue pole where scanning began, so the walker can return to it to close the loop.
    func showStart(_ position: SIMD3<Float>?) {
        startEntity = pole(replacing: startEntity, at: position, color: .systemBlue)
    }

    /// Orange pole at the spot to return to after tracking was lost.
    func showRecovery(_ position: SIMD3<Float>?) {
        recoveryEntity = pole(replacing: recoveryEntity, at: position, color: .systemOrange)
    }

    private func pole(replacing old: ModelEntity?, at position: SIMD3<Float>?, color: UIColor) -> ModelEntity? {
        old?.removeFromParent()
        guard let position else { return nil }
        let pole = ModelEntity(mesh: .generateCylinder(height: 1.2, radius: 0.04),
                               materials: [SimpleMaterial(color: color, isMetallic: false)])
        pole.position = position + SIMD3<Float>(0, 0.6, 0)
        root?.addChild(pole)
        return pole
    }

    /// Red disc marking the area around the cup that the route stays out of.
    func showCup(_ position: SIMD3<Float>?, keepOutRadius: Float) {
        cupEntity?.removeFromParent()
        cupEntity = nil
        guard let position else { return }
        let disc = ModelEntity(mesh: .generateCylinder(height: 0.01, radius: keepOutRadius), materials: [keepOutMaterial])
        disc.position = position + SIMD3<Float>(0, 0.015, 0)
        root?.addChild(disc)
        cupEntity = disc
    }

    private func makeRibbon(_ points: [SIMD3<Float>], width: Float) -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let direction = SIMD3<Float>(b.x - a.x, 0, b.z - a.z)
            let length = simd_length(direction)
            guard length > 0.01 else { continue }
            let side = SIMD3<Float>(-direction.z, 0, direction.x) / length * (width / 2)
            let base = UInt32(positions.count)
            positions.append(contentsOf: [a + side, b + side, b - side, a - side])
            // Both windings, so the ribbon is visible whichever way the quad faces.
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3,
                                        base, base + 2, base + 1, base, base + 3, base + 2])
        }
        guard !positions.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "walk-route")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals([SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: positions.count))
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    private func update(_ entity: ModelEntity?, tiles: [MapTile], origin: SIMD3<Float>,
                        material: SimpleMaterial) -> ModelEntity? {
        guard let mesh = makeMesh(tiles, origin: origin) else {
            entity?.removeFromParent()
            return nil
        }
        if let entity {
            entity.model?.mesh = mesh
            return entity
        }
        let created = ModelEntity(mesh: mesh, materials: [material])
        root?.addChild(created)
        return created
    }

    private func makeMesh(_ tiles: [MapTile], origin: SIMD3<Float>) -> MeshResource? {
        guard !tiles.isEmpty else { return nil }
        let half = GreenMapAccumulator.cellSize / 2
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(tiles.count * 4)
        indices.reserveCapacity(tiles.count * 6)
        for tile in tiles {
            let cx = tile.x + origin.x
            let cz = tile.z + origin.z
            let y = tile.y + origin.y + 0.012
            let base = UInt32(positions.count)
            positions.append(SIMD3<Float>(cx - half, y, cz - half))
            positions.append(SIMD3<Float>(cx + half, y, cz - half))
            positions.append(SIMD3<Float>(cx + half, y, cz + half))
            positions.append(SIMD3<Float>(cx - half, y, cz + half))
            // Counter-clockwise when viewed from above so the quads face up.
            indices.append(contentsOf: [base, base + 3, base + 2, base, base + 2, base + 1])
        }
        var descriptor = MeshDescriptor(name: "coverage")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals([SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: positions.count))
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }
}
