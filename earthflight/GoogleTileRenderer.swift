import RealityKit
import UIKit
import Metal
import simd

/// Cesium's tiles as RealityKit entities. A tile is built while Cesium waits,
/// then kept hidden until Cesium selects it. Each selection is shown in one
/// step, and Cesium reports one only once every tile in it is ready, so two
/// levels of detail never overlap and a half-loaded area never opens a hole.
@MainActor
final class GoogleTileRenderer {
    let earthRoot = Entity()

    private struct Primitive {
        let entity: Entity
        let ecefFromLocal: simd_double4x4
    }

    private struct Tile {
        /// A child of `earthRoot`, enabled exactly while the tile is shown.
        let container: Entity
        let primitives: [Primitive]
    }

    private var tiles: [UInt64: Tile] = [:]
    /// Tiles whose RealityKit resources are still being built. A tile freed in
    /// the meantime leaves this set and must not be installed afterwards.
    private var tilesBeingPrepared: Set<UInt64> = []
    private var shownTiles: Set<UInt64> = []

    /// The floating render frame every tile is placed in. Assign it every
    /// frame: tiles move only when it has changed, after a rebase or a jump.
    var renderLocalFromEcef: simd_double4x4 {
        didSet {
            guard renderLocalFromEcef != oldValue else { return }
            for tile in tiles.values {
                tile.primitives.forEach(place)
            }
        }
    }

    init(renderLocalFromEcef: simd_double4x4) {
        self.renderLocalFromEcef = renderLocalFromEcef
    }

    /// Shows exactly the selected tiles, as one main-actor change with nothing
    /// in between.
    func show(_ selection: Set<UInt64>) {
        assert(selection.allSatisfy { tiles[$0] != nil }, "Cesium selected a tile RealityKit has not built")
        for tileIdentifier in shownTiles.subtracting(selection) {
            tiles[tileIdentifier]?.container.isEnabled = false
        }
        for tileIdentifier in selection.subtracting(shownTiles) {
            tiles[tileIdentifier]?.container.isEnabled = true
        }
        shownTiles = selection
    }

    /// Builds a tile's entities for Cesium, which waits on
    /// `CesiumBridge.finishPreparingTile` before it may select the tile.
    func prepare(tileIdentifier: UInt64, payloads: [CesiumPrimitivePayload]) {
        tilesBeingPrepared.insert(tileIdentifier)
        Task {
            var primitives: [Primitive] = []
            do {
                for payload in payloads {
                    primitives.append(try await Self.makePrimitive(from: payload))
                }
            } catch {
                print("Google tile \(tileIdentifier) skipped: \(error)")
            }
            // A tile with a primitive missing would cover its ground only in
            // part, so that counts as failure, as does a tile freed meanwhile.
            guard tilesBeingPrepared.remove(tileIdentifier) != nil,
                  primitives.count == payloads.count else {
                CesiumBridge.finishPreparingTile(tileIdentifier, succeeded: false)
                return
            }
            let container = Entity()
            container.isEnabled = false
            for primitive in primitives {
                // Placed with the render frame current now, not when building
                // started: a rebase or a Jump To may have happened since.
                place(primitive)
                container.addChild(primitive.entity)
            }
            earthRoot.addChild(container)
            tiles[tileIdentifier] = Tile(container: container, primitives: primitives)
            CesiumBridge.finishPreparingTile(tileIdentifier, succeeded: true)
        }
    }

    func remove(tileIdentifier: UInt64) {
        tilesBeingPrepared.remove(tileIdentifier)
        shownTiles.remove(tileIdentifier)
        tiles.removeValue(forKey: tileIdentifier)?.container.removeFromParent()
    }

    private func place(_ primitive: Primitive) {
        // primitive-local -> ECEF -> current render-local, in Double metres,
        // cast to Float only once composed.
        primitive.entity.transform = Transform(
            matrix: simd_float4x4(renderLocalFromEcef * primitive.ecefFromLocal)
        )
    }

    private static func makePrimitive(from payload: CesiumPrimitivePayload) async throws -> Primitive {
        // The bridge has already checked the shapes and that every index is in
        // range, and laid the buffers out as the arrays RealityKit takes.
        var descriptor = MeshDescriptor(name: "Google Photorealistic Tile")
        descriptor.positions = MeshBuffers.Positions(payload.positions.array())
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(payload.textureCoordinates.array())
        descriptor.primitives = .triangles(payload.indices.array())

        let mesh = try MeshResource.generate(from: [descriptor])
        let texture = try await makeTexture(
            rgba8: payload.rgbaImage,
            width: payload.imageWidth,
            height: payload.imageHeight
        )
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture, sampler: sampler(for: payload)))
        material.faceCulling = payload.doubleSided ? .none : .back
        return Primitive(
            entity: ModelEntity(mesh: mesh, materials: [material]),
            ecefFromLocal: payload.ecefFromPrimitiveLocal
        )
    }

    /// Cesium's decoded RGBA8 texels, top row first, as a RealityKit texture.
    /// Internal so the regression test exercises the same upload as streaming.
    static func makeTexture(rgba8: Data, width: Int, height: Int) async throws -> TextureResource {
        try await TextureResource(
            image: .rgba8(rgba8, width: width, height: height, alpha: .last),
            options: TextureResource.CreateOptions(semantic: .color)
        )
    }

    /// The glTF sampler, set explicitly rather than trusting RealityKit's
    /// defaults. The numbers are glTF's, which are OpenGL's.
    private static func sampler(
        for payload: CesiumPrimitivePayload
    ) -> MaterialParameters.Texture.Sampler {
        var sampler = MaterialParameters.Texture.Sampler()
        sampler.modify { descriptor in
            descriptor.sAddressMode = addressMode(payload.samplerWrapS)
            descriptor.tAddressMode = addressMode(payload.samplerWrapT)
            (descriptor.minFilter, descriptor.mipFilter) = switch payload.samplerMinFilter {
            case 9728: (.nearest, .notMipmapped) // NEAREST
            case 9729: (.linear, .notMipmapped)  // LINEAR
            case 9984: (.nearest, .nearest)      // NEAREST_MIPMAP_NEAREST
            case 9985: (.linear, .nearest)       // LINEAR_MIPMAP_NEAREST
            case 9986: (.nearest, .linear)       // NEAREST_MIPMAP_LINEAR
            default: (.linear, .linear)          // LINEAR_MIPMAP_LINEAR, glTF's default
            }
            descriptor.magFilter = payload.samplerMagFilter == 9728 ? .nearest : .linear
        }
        return sampler
    }

    private static func addressMode(_ gltfWrapMode: Int) -> MTLSamplerAddressMode {
        switch gltfWrapMode {
        case 33071: .clampToEdge  // CLAMP_TO_EDGE
        case 33648: .mirrorRepeat // MIRRORED_REPEAT
        default: .repeat          // REPEAT
        }
    }
}

private extension Data {
    /// The bytes copied out as an array of whatever the bridge wrote them as.
    func array<Element>() -> [Element] {
        withUnsafeBytes { Array($0.bindMemory(to: Element.self)) }
    }
}
