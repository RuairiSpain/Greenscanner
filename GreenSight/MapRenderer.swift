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

    private let edgeMaterial = SimpleMaterial(color: .white, isMetallic: false)
    private let pointMaterial = SimpleMaterial(color: .systemMint, isMetallic: false)
    private let goodMaterial = SimpleMaterial(color: UIColor.systemGreen.withAlphaComponent(0.55), isMetallic: false)
    private let weakMaterial = SimpleMaterial(color: UIColor.systemOrange.withAlphaComponent(0.55), isMetallic: false)

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
    func showCoverage(good: [MapTile], weak: [MapTile], origin: SIMD3<Float>) {
        goodEntity = update(goodEntity, tiles: good, origin: origin, material: goodMaterial)
        weakEntity = update(weakEntity, tiles: weak, origin: origin, material: weakMaterial)
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
