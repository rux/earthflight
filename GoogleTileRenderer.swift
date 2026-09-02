import RealityKit
import UIKit
import Metal
import simd

@MainActor
final class GoogleTileRenderer {
    let earthRoot = Entity()
    private struct AnchoredEntity {
        let entity: Entity
        let ecefFromPrimitiveLocal: simd_double4x4
    }

    private var entitiesByTileIdentifier: [String: [AnchoredEntity]] = [:]
    private var visibleTileIdentifiers: Set<String> = []
    private var installingTileIdentifiers: Set<String> = []
    private var tileGenerations: [String: Int] = [:]
    private var renderLocalFromEcef: simd_double4x4

    init(renderLocalFromEcef: simd_double4x4) {
        self.renderLocalFromEcef = renderLocalFromEcef
    }

    func setRenderFrame(renderLocalFromEcef: simd_double4x4) {
        self.renderLocalFromEcef = renderLocalFromEcef
        for anchoredEntities in entitiesByTileIdentifier.values {
            for anchoredEntity in anchoredEntities {
                applyCurrentPlacement(to: anchoredEntity)
            }
        }
    }

    func show(primitives: [CesiumPrimitivePayload], for tileIdentifier: String) {
        visibleTileIdentifiers.insert(tileIdentifier)
        if let entities = entitiesByTileIdentifier[tileIdentifier] {
            for anchoredEntity in entities {
                anchoredEntity.entity.isEnabled = true
            }
            return
        }
        guard !installingTileIdentifiers.contains(tileIdentifier) else {
            return
        }
        installingTileIdentifiers.insert(tileIdentifier)
        let generation = tileGenerations[tileIdentifier, default: 0]

        Task {
            await install(primitives: primitives, for: tileIdentifier, generation: generation)
        }
    }

    func hide(tileIdentifier: String) {
        visibleTileIdentifiers.remove(tileIdentifier)
        if installingTileIdentifiers.contains(tileIdentifier) {
            tileGenerations[tileIdentifier, default: 0] += 1
        }
        for anchoredEntity in entitiesByTileIdentifier[tileIdentifier] ?? [] {
            anchoredEntity.entity.isEnabled = false
        }
    }

    private func install(
        primitives: [CesiumPrimitivePayload],
        for tileIdentifier: String,
        generation: Int
    ) async {
        defer {
            installingTileIdentifiers.remove(tileIdentifier)
            if entitiesByTileIdentifier[tileIdentifier] == nil {
                tileGenerations.removeValue(forKey: tileIdentifier)
            }
        }

        var entities: [AnchoredEntity] = []
        for (_, payload) in primitives.enumerated() {
            if let entity = await makeEntity(
                from: payload
            ) {
                entities.append(entity)
            }
        }
        guard visibleTileIdentifiers.contains(tileIdentifier),
              tileGenerations[tileIdentifier, default: 0] == generation,
              !entities.isEmpty else {
            return
        }

        for anchoredEntity in entities {
            // Resource generation may span a rebase. Placement deliberately uses
            // the renderer's latest frame only at main-actor installation time.
            applyCurrentPlacement(to: anchoredEntity)
            earthRoot.addChild(anchoredEntity.entity)
        }
        entitiesByTileIdentifier[tileIdentifier] = entities
        tileGenerations.removeValue(forKey: tileIdentifier)
    }

    func remove(tileIdentifier: String) {
        visibleTileIdentifiers.remove(tileIdentifier)
        if installingTileIdentifiers.contains(tileIdentifier) {
            tileGenerations[tileIdentifier, default: 0] += 1
        } else {
            tileGenerations.removeValue(forKey: tileIdentifier)
        }
        guard let entities = entitiesByTileIdentifier.removeValue(forKey: tileIdentifier) else {
            return
        }
        for anchoredEntity in entities {
            anchoredEntity.entity.removeFromParent()
        }
    }

#if DEBUG
    var debugResourceSummary: String {
        let entityCount = entitiesByTileIdentifier.values.reduce(0) { $0 + $1.count }
        return "visibleTiles=\(visibleTileIdentifiers.count) cachedTiles=\(entitiesByTileIdentifier.count) entities=\(entityCount) pendingInstalls=\(installingTileIdentifiers.count) generationTokens=\(tileGenerations.count)"
    }
#endif

    private func makeEntity(
        from payload: CesiumPrimitivePayload
    ) async -> AnchoredEntity? {
        let positionFloats = floats(from: payload.positions)
        let uvFloats = floats(from: payload.textureCoordinates)
        let indices = uint32s(from: payload.indices)

        guard positionFloats.count.isMultiple(of: 3),
              uvFloats.count.isMultiple(of: 2),
              positionFloats.count / 3 == uvFloats.count / 2,
              indices.count.isMultiple(of: 3) else {
            print("Google RealityKit primitive skipped: malformed bridge payload")
            return nil
        }

        let positions = stride(from: 0, to: positionFloats.count, by: 3).map {
            SIMD3(positionFloats[$0], positionFloats[$0 + 1], positionFloats[$0 + 2])
        }
        let textureCoordinates = stride(from: 0, to: uvFloats.count, by: 2).map {
            SIMD2(uvFloats[$0], uvFloats[$0 + 1])
        }
        guard indices.allSatisfy({ Int($0) < positions.count }) else {
            print("Google RealityKit primitive skipped: index exceeds vertex count")
            return nil
        }

        do {
            var descriptor = MeshDescriptor(name: "Google Photorealistic Tile")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(textureCoordinates)
            descriptor.primitives = .triangles(indices)

            let mesh = try MeshResource.generate(from: [descriptor])
            var material = UnlitMaterial()
            let texture = try await makeTexture(from: payload)
            let textureParameter = MaterialParameters.Texture(
                texture,
                sampler: makeSampler(from: payload)
            )
            material.color = .init(tint: .white, texture: textureParameter)
            // glTF's `doubleSided` controls whether back-face culling is disabled.
            material.faceCulling = payload.doubleSided ? .none : .back
            return AnchoredEntity(
                entity: ModelEntity(mesh: mesh, materials: [material]),
                ecefFromPrimitiveLocal: payload.ecefFromPrimitiveLocal
            )
        } catch {
            print("Google RealityKit primitive skipped: \(error)")
            return nil
        }
    }

    private func applyCurrentPlacement(to anchoredEntity: AnchoredEntity) {
        // primitive-local -> ECEF -> current render-local, all in Double metres.
        // This is the only matrix cast used to place the retained RealityKit entity.
        let renderLocalFromPrimitiveLocal =
            renderLocalFromEcef * anchoredEntity.ecefFromPrimitiveLocal
        anchoredEntity.entity.transform = Transform(
            matrix: FlightState.realityKitMatrix(renderLocalFromPrimitiveLocal)
        )
    }

    // Cesium supplies decoded, tightly-packed RGBA8 pixels. Upload those bytes
    // directly rather than passing through Core Graphics, whose bitmap layout is
    // unnecessary here and obscures the source pixel-format contract.
    private func makeTexture(
        from payload: CesiumPrimitivePayload
    ) async throws -> TextureResource {
        guard payload.imageWidth > 0,
              payload.imageHeight > 0,
              payload.rgbaImage.count == payload.imageWidth * payload.imageHeight * 4 else {
            throw GoogleTileRendererError.invalidImage
        }

        let contents = TextureResource.Contents(
            mipmapLevels: [
                .mip(data: payload.rgbaImage, bytesPerRow: payload.imageWidth * 4)
            ]
        )
        return try await TextureResource(
            dimensions: .dimensions(width: payload.imageWidth, height: payload.imageHeight),
            format: .color(.displayP3, pixelFormat: .rgba8Unorm),
            contents: contents
        )
    }

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
            default: // LINEAR_MIPMAP_LINEAR, including the glTF default
                descriptor.minFilter = .linear
                descriptor.mipFilter = .linear
            }
            descriptor.magFilter = payload.samplerMagFilter == 9728 ? .nearest : .linear
        }
        return sampler
    }

    private func addressMode(for gltfWrapMode: Int) -> MTLSamplerAddressMode {
        switch gltfWrapMode {
        case 33071:
            return .clampToEdge
        case 33648:
            return .mirrorRepeat
        default:
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
