import RealityKit
import UIKit

@MainActor
final class GoogleTileRenderer {
    let earthRoot = Entity()
    private var entitiesByTileIdentifier: [String: [Entity]] = [:]
    private var installingTileIdentifiers: Set<String> = []
    private var tileGenerations: [String: Int] = [:]

    func install(primitives: [CesiumPrimitivePayload], for tileIdentifier: String) async {
        guard entitiesByTileIdentifier[tileIdentifier] == nil,
              !installingTileIdentifiers.contains(tileIdentifier) else {
            return
        }
        installingTileIdentifiers.insert(tileIdentifier)
        let generation = tileGenerations[tileIdentifier, default: 0]
        defer { installingTileIdentifiers.remove(tileIdentifier) }

        var entities: [Entity] = []
        for (_, payload) in primitives.enumerated() {
            if let entity = await makeEntity(
                from: payload
            ) {
                entities.append(entity)
            }
        }
        guard tileGenerations[tileIdentifier, default: 0] == generation,
              !entities.isEmpty else {
            return
        }

        for entity in entities {
            earthRoot.addChild(entity)
        }
        entitiesByTileIdentifier[tileIdentifier] = entities
        print("Google RealityKit tile installed: primitives=\(entities.count)")
    }

    func remove(tileIdentifier: String) {
        tileGenerations[tileIdentifier, default: 0] += 1
        guard let entities = entitiesByTileIdentifier.removeValue(forKey: tileIdentifier) else {
            return
        }
        for entity in entities {
            entity.removeFromParent()
        }
    }

    private func makeEntity(
        from payload: CesiumPrimitivePayload
    ) async -> ModelEntity? {
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
            material.color = .init(tint: .white, texture: MaterialParameters.Texture(texture))
            // glTF's `doubleSided` controls whether back-face culling is disabled.
            material.faceCulling = payload.doubleSided ? .none : .back
            return ModelEntity(mesh: mesh, materials: [material])
        } catch {
            print("Google RealityKit primitive skipped: \(error)")
            return nil
        }
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
