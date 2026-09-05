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

    private final class TileEntities {
        // Starts disabled so a tile still being prepared is never a candidate
        // for retirement, and so nothing empty is ever briefly in the scene.
        let container: Entity = {
            let container = Entity()
            container.isEnabled = false
            return container
        }()
        var anchoredEntities: [AnchoredEntity] = []
        // Installation has concluded, whether or not it yielded geometry.
        // A non-empty `anchoredEntities` cannot say that on its own: a payload
        // that produces nothing usable would otherwise be rebuilt every frame
        // and would count as pending forever, jamming the bridge's hide gate.
        var isInstalled = false
        // The update on which Cesium last selected this tile. Retirement is the
        // difference between what is drawn and what was selected just now.
        var lastSelectedUpdate = 0
    }

    private var tileEntitiesByIdentifier: [String: TileEntities] = [:]
    private var installingTileIdentifiers: Set<String> = []
    private var currentUpdate = 0
    private var renderLocalFromEcef: simd_double4x4

    // Temporary, alongside the bridge's per-second summary. A tile Cesium frees
    // while Earthflight is still drawing it vanishes with no handoff at all.
    private var removedWhileVisibleCount = 0

    init(renderLocalFromEcef: simd_double4x4) {
        self.renderLocalFromEcef = renderLocalFromEcef
    }

    func setRenderFrame(renderLocalFromEcef: simd_double4x4) {
        self.renderLocalFromEcef = renderLocalFromEcef
        for tileEntities in tileEntitiesByIdentifier.values {
            for anchoredEntity in tileEntities.anchoredEntities {
                applyCurrentPlacement(to: anchoredEntity)
            }
        }
    }

    /// Called once per scene update, before the tiles selected by that update
    /// are shown, so `retireTilesNotSelectedThisUpdate` can tell the two apart.
    func beginUpdate() {
        currentUpdate &+= 1
    }

    /// Hide everything still on screen that Cesium did not select this update.
    /// The bridge calls this only once every selected tile is installed, so a
    /// replacement is always present before its predecessor goes.
    func retireTilesNotSelectedThisUpdate() {
        guard EarthflightTuning.retireOutgoingTiles else { return }
        for (tileIdentifier, tileEntities) in tileEntitiesByIdentifier
        where tileEntities.container.isEnabled
            && tileEntities.lastSelectedUpdate != currentUpdate {
            hide(tileIdentifier: tileIdentifier)
        }
    }

    func show(primitives: [CesiumPrimitivePayload], for tileIdentifier: String) {
        let tileEntities: TileEntities
        if let existing = tileEntitiesByIdentifier[tileIdentifier] {
            tileEntities = existing
        } else {
            tileEntities = TileEntities()
            tileEntitiesByIdentifier[tileIdentifier] = tileEntities
        }
        tileEntities.lastSelectedUpdate = currentUpdate
        if tileEntities.isInstalled {
            tileEntities.container.isEnabled = true
            return
        }
        guard !installingTileIdentifiers.contains(tileIdentifier) else {
            return
        }
        installingTileIdentifiers.insert(tileIdentifier)

        Task {
            await install(
                primitives: primitives,
                for: tileIdentifier,
                tileEntities: tileEntities
            )
        }
    }

    func hide(tileIdentifier: String) {
        tileEntitiesByIdentifier[tileIdentifier]?.container.isEnabled = false
    }

    private func install(
        primitives: [CesiumPrimitivePayload],
        for tileIdentifier: String,
        tileEntities: TileEntities
    ) async {
        defer { installingTileIdentifiers.remove(tileIdentifier) }

        var entities: [AnchoredEntity] = []
        for payload in primitives {
            if let entity = await makeEntity(
                from: payload
            ) {
                entities.append(entity)
            }
        }
        // Identity is the only guard needed. `remove` drops the dictionary
        // entry, so a freed tile can never be reattached under a later
        // TileEntities, and a tile merely deselected while preparing keeps the
        // work: discarding it left that ground uncovered for far longer than
        // the deselection lasted.
        guard tileEntitiesByIdentifier[tileIdentifier] === tileEntities else {
            return
        }

        for anchoredEntity in entities {
            // Resource generation may span a rebase. Placement deliberately uses
            // the renderer's latest frame only at main-actor installation time.
            applyCurrentPlacement(to: anchoredEntity)
            tileEntities.container.addChild(anchoredEntity.entity)
        }
        tileEntities.anchoredEntities = entities
        tileEntities.isInstalled = true
        // Visibility follows the current selection, not whether the install
        // happened to survive it, so a tile finishing while selected is drawn
        // immediately rather than one frame later when show() next runs.
        tileEntities.container.isEnabled =
            tileEntities.lastSelectedUpdate == currentUpdate
        earthRoot.addChild(tileEntities.container)
        // The bridge keeps the outgoing LOD on screen until this fires. Report
        // even when the payload produced no geometry: one unusable tile must not
        // stop every outgoing tile from ever being hidden.
        CesiumBridge.tileDidFinishInstalling(tileIdentifier)
    }

    func remove(tileIdentifier: String) {
        guard let tileEntities = tileEntitiesByIdentifier.removeValue(forKey: tileIdentifier) else {
            return
        }
        if tileEntities.isInstalled && tileEntities.container.isEnabled {
            removedWhileVisibleCount += 1
            print("Earthflight: removed a visible tile (\(removedWhileVisibleCount) so far)")
        }
        tileEntities.container.removeFromParent()
    }

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
