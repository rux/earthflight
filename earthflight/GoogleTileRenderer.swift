import RealityKit
import UIKit
import Metal
import simd

/// Cesium's tiles as RealityKit entities. A tile is built while Cesium waits,
/// then kept hidden until Cesium selects it. Each update's selection is shown
/// in one step, and only once every tile in it is ready, so two levels of
/// detail never overlap and a half-loaded area never opens a hole.
@MainActor
final class GoogleTileRenderer {
    let earthRoot = Entity()

    private struct AnchoredEntity {
        let entity: Entity
        let ecefFromPrimitiveLocal: simd_double4x4
    }

    private struct Tile {
        /// A child of `earthRoot`, enabled exactly while the tile is shown.
        let container: Entity
        let primitives: [AnchoredEntity]
    }

    private var tiles: [UInt64: Tile] = [:]
    /// Tiles whose RealityKit resources are still being built. A tile freed in
    /// the meantime leaves this set and must not be installed afterwards.
    private var tilesBeingPrepared: Set<UInt64> = []
    /// What Cesium has selected so far in the current update.
    private var selectedTiles: Set<UInt64> = []
    private var shownTiles: Set<UInt64> = []
    private var renderLocalFromEcef: simd_double4x4

    init(renderLocalFromEcef: simd_double4x4) {
        self.renderLocalFromEcef = renderLocalFromEcef
    }

    func setRenderFrame(renderLocalFromEcef: simd_double4x4) {
        self.renderLocalFromEcef = renderLocalFromEcef
        for tile in tiles.values {
            for primitive in tile.primitives {
                place(primitive)
            }
        }
    }

    /// Called once per scene update, before Cesium reports that update's
    /// selection.
    func beginSelection() {
        selectedTiles.removeAll(keepingCapacity: true)
    }

    func markSelected(tileIdentifier: UInt64) {
        assert(tiles[tileIdentifier] != nil, "Cesium selected a tile RealityKit has not built")
        selectedTiles.insert(tileIdentifier)
    }

    /// Shows this update's selection and hides everything else, as one
    /// main-actor change with nothing in between.
    func showSelection() {
        for tileIdentifier in shownTiles.subtracting(selectedTiles) {
            tiles[tileIdentifier]?.container.isEnabled = false
        }
        for tileIdentifier in selectedTiles.subtracting(shownTiles) {
            tiles[tileIdentifier]?.container.isEnabled = true
        }
        shownTiles = selectedTiles
    }

    /// Builds a tile's entities for Cesium, which waits on
    /// `CesiumBridge.tileDidFinishPreparing` before it may select the tile.
    func prepare(tileIdentifier: UInt64, primitives: [CesiumPrimitivePayload]) {
        tilesBeingPrepared.insert(tileIdentifier)
        Task {
            var entities: [AnchoredEntity] = []
            for payload in primitives {
                if let entity = await makeEntity(from: payload) {
                    entities.append(entity)
                }
            }
            // A tile with a primitive missing would cover its ground only in
            // part, so that counts as failure.
            guard tilesBeingPrepared.remove(tileIdentifier) != nil,
                  entities.count == primitives.count else {
                CesiumBridge.tileDidFinishPreparing(tileIdentifier, succeeded: false)
                return
            }
            let container = Entity()
            container.isEnabled = false
            for primitive in entities {
                // Placed with the render frame current now, not when building
                // started: a rebase or a Jump To may have happened since.
                place(primitive)
                container.addChild(primitive.entity)
            }
            earthRoot.addChild(container)
            tiles[tileIdentifier] = Tile(container: container, primitives: entities)
            CesiumBridge.tileDidFinishPreparing(tileIdentifier, succeeded: true)
        }
    }

    func remove(tileIdentifier: UInt64) {
        tilesBeingPrepared.remove(tileIdentifier)
        selectedTiles.remove(tileIdentifier)
        shownTiles.remove(tileIdentifier)
        tiles.removeValue(forKey: tileIdentifier)?.container.removeFromParent()
    }

    private func place(_ primitive: AnchoredEntity) {
        // primitive-local -> ECEF -> current render-local, in Double metres,
        // cast to Float only once composed.
        primitive.entity.transform = Transform(
            matrix: simd_float4x4(renderLocalFromEcef * primitive.ecefFromPrimitiveLocal)
        )
    }

    private func makeEntity(from payload: CesiumPrimitivePayload) async -> AnchoredEntity? {
        // The bridge has already checked the shapes and that every index is in
        // range.
        let positionFloats = floats(from: payload.positions)
        let uvFloats = floats(from: payload.textureCoordinates)
        let positions = stride(from: 0, to: positionFloats.count, by: 3).map {
            SIMD3(positionFloats[$0], positionFloats[$0 + 1], positionFloats[$0 + 2])
        }
        let textureCoordinates = stride(from: 0, to: uvFloats.count, by: 2).map {
            SIMD2(uvFloats[$0], uvFloats[$0 + 1])
        }

        do {
            var descriptor = MeshDescriptor(name: "Google Photorealistic Tile")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(textureCoordinates)
            descriptor.primitives = .triangles(uint32s(from: payload.indices))

            let mesh = try MeshResource.generate(from: [descriptor])
            let texture = try await Self.makeTexture(
                rgba8: payload.rgbaImage,
                width: payload.imageWidth,
                height: payload.imageHeight
            )
            var material = UnlitMaterial()
            material.color = .init(
                tint: .white,
                texture: MaterialParameters.Texture(texture, sampler: makeSampler(from: payload))
            )
            material.faceCulling = payload.doubleSided ? .none : .back
            return AnchoredEntity(
                entity: ModelEntity(mesh: mesh, materials: [material]),
                ecefFromPrimitiveLocal: payload.ecefFromPrimitiveLocal
            )
        } catch {
            print("Google tile primitive skipped: \(error)")
            return nil
        }
    }

    /// Cesium's decoded RGBA8 texels, top row first, as a RealityKit texture.
    /// Internal so the regression test exercises the same upload as streaming.
    static func makeTexture(
        rgba8: Data,
        width: Int,
        height: Int
    ) async throws -> TextureResource {
        guard width > 0,
              height > 0,
              rgba8.count == width * height * 4 else {
            throw GoogleTileRendererError.invalidImage
        }

        // Through a CGImage, not the raw-contents initialiser: the raw path
        // showed one white frame before every new texture on the M2 Vision Pro,
        // even after a completed GPU copy proved its pixels readable.
        //
        // glTF base-colour texels are sRGB, and saying so is what makes
        // RealityKit convert them to Display P3. Labelling them Display P3
        // skips that conversion and oversaturates every strong colour.
        guard let provider = CGDataProvider(data: rgba8 as CFData),
              let colourSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colourSpace,
                bitmapInfo: [
                    .byteOrder32Big,
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                ],
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw GoogleTileRendererError.invalidImage
        }
        return try await TextureResource(
            image: image,
            options: TextureResource.CreateOptions(semantic: .color)
        )
    }

    /// The glTF sampler, set explicitly rather than trusting RealityKit's
    /// defaults. The numbers are glTF's, which are OpenGL's.
    private func makeSampler(
        from payload: CesiumPrimitivePayload
    ) -> MaterialParameters.Texture.Sampler {
        var sampler = MaterialParameters.Texture.Sampler()
        sampler.modify { descriptor in
            descriptor.sAddressMode = addressMode(for: payload.samplerWrapS)
            descriptor.tAddressMode = addressMode(for: payload.samplerWrapT)

            switch payload.samplerMinFilter {
            case 9728: // NEAREST
                descriptor.minFilter = .nearest
                descriptor.mipFilter = .notMipmapped
            case 9729: // LINEAR
                descriptor.minFilter = .linear
                descriptor.mipFilter = .notMipmapped
            case 9984: // NEAREST_MIPMAP_NEAREST
                descriptor.minFilter = .nearest
                descriptor.mipFilter = .nearest
            case 9985: // LINEAR_MIPMAP_NEAREST
                descriptor.minFilter = .linear
                descriptor.mipFilter = .nearest
            case 9986: // NEAREST_MIPMAP_LINEAR
                descriptor.minFilter = .nearest
                descriptor.mipFilter = .linear
            default: // LINEAR_MIPMAP_LINEAR, glTF's default
                descriptor.minFilter = .linear
                descriptor.mipFilter = .linear
            }
            descriptor.magFilter = payload.samplerMagFilter == 9728 ? .nearest : .linear
        }
        return sampler
    }

    private func addressMode(for gltfWrapMode: Int) -> MTLSamplerAddressMode {
        switch gltfWrapMode {
        case 33071: // CLAMP_TO_EDGE
            return .clampToEdge
        case 33648: // MIRRORED_REPEAT
            return .mirrorRepeat
        default: // REPEAT
            return .repeat
        }
    }

    private func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }

    private func uint32s(from data: Data) -> [UInt32] {
        data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: UInt32.self))
        }
    }

    private enum GoogleTileRendererError: Error {
        case invalidImage
    }
}
