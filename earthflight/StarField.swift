import CoreGraphics
import Foundation
import RealityKit
import UIKit
import simd

// A sprinkle of white points on a sphere just inside the sky dome, so that
// black space does not feel empty. It is not a star map. Three decisions carry
// the illusion, and none of them needs a shader.
//
//  * The field is anchored to ECEF rather than to the render frame. Render-local
//    axes rotate as the craft flies and jump by up to half a degree at every
//    50 km rebase. The sky gradient is symmetric about its own up axis, so that
//    rotation goes unnoticed there, but pinpoint stars would visibly pop.
//    Countering it pins the stars to the Earth. The dome also carries its own
//    rotation to current geodetic up, so the field must cancel that too, or the
//    stars would rotate twice.
//  * Stars fade in with the same air mass that colours the sky: drowned at
//    ground level and full by about 40 km, with no separate mode or trigger.
//  * Twinkling is done in banks. The stars are split across several meshes whose
//    opacities breathe on different periods, which is far cheaper than animating
//    a thousand points one by one and reads as shimmer. Real stars do not
//    twinkle in a vacuum; this is a deliberate untruth.
//
// Each star is a quad carrying one shared opacity texture: full brightness out
// to seven tenths of the way to the edge, then a smooth shoulder to nothing.
// Plain quads were visibly square on the headset. The texture also mipmaps, so a
// star a pixel or two across is averaged down to a steady dim point instead of
// flickering as the head turns; that costs roughly two fifths of its
// brightness, which is why the twinkle floor sits as high as it does.

/// Deterministic so the sky does not reshuffle between launches. A 64-bit linear
/// congruential step with a SplitMix finaliser is ample for scattering points.
private struct StarRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func unitInterval() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        mixed ^= mixed >> 31
        return Double(mixed >> 11) * 0x1p-53
    }
}

@MainActor
final class StarField {
    /// Parent of every bank. Scaled just inside the sky dome and rotated each
    /// update so the whole field stays fixed to the Earth.
    let entity = Entity()

    /// One mesh per twinkle period, each breathing through its own
    /// `OpacityComponent`.
    private let banks: [ModelEntity]
    private var elapsedSeconds = 0.0

    init() async {
        banks = Self.makeBanks(dotTexture: await Self.makeDotTexture())
        entity.scale = .init(repeating: EarthflightTuning.starFieldRadiusFraction)
        for bank in banks {
            entity.addChild(bank)
        }
    }

    /// The sky's brightness at the zenith is what hides stars, and here that is
    /// the same air mass the gradient uses: 1 at sea level, 0.03 at 30 km,
    /// effectively nothing past the Karman line. Stars start to show at around
    /// 15 km and are full by 40 km.
    nonisolated static func visibility(ellipsoidHeightMeters: Double) -> Double {
        let zenithAirMass = SkyAtmosphere.zenithAirMass(heightMeters: ellipsoidHeightMeters)
        return exp(-zenithAirMass / EarthflightTuning.starZenithAirMassFade)
    }

    func update(
        ellipsoidHeightMeters: Double,
        renderLocalFromEcef: simd_double4x4,
        skyOrientation: simd_quatf,
        deltaTime: TimeInterval
    ) {
        let visibility = Self.visibility(ellipsoidHeightMeters: ellipsoidHeightMeters)
        // Below this the stars are a fraction of one 8-bit level. Disabling the
        // field keeps a thousand transparent quads out of all ordinary low
        // flight.
        guard visibility > 0.004 else {
            entity.isEnabled = false
            return
        }
        entity.isEnabled = true
        elapsedSeconds += deltaTime

        // render-local -> ECEF cancels the render frame's rotation, so a
        // direction in bank-local space always means the same direction on the
        // Earth. `skyOrientation.inverse` then cancels the parent dome's own
        // rotation, which would otherwise be applied on top. Writing the
        // orientation leaves the scale set at construction alone.
        entity.orientation = skyOrientation.inverse * Self.earthAnchoredOrientation(
            renderLocalFromEcef: renderLocalFromEcef
        )

        for (index, bank) in banks.enumerated() {
            let period = EarthflightTuning.starTwinklePeriodsSeconds[index]
            // The per-bank offset only matters at launch, when every bank would
            // otherwise start at the same point in its cycle.
            let phase = 2 * Double.pi * (elapsedSeconds / period + Double(index) * 0.37)
            let twinkle = EarthflightTuning.starTwinkleBaseBrightness +
                EarthflightTuning.starTwinkleAmplitude * sin(phase)
            bank.components.set(OpacityComponent(opacity: Float(visibility * twinkle)))
        }
    }

    nonisolated static func earthAnchoredOrientation(
        renderLocalFromEcef: simd_double4x4
    ) -> simd_quatf {
        simd_quatf(rotationOf: renderLocalFromEcef)
    }

    /// A round dot with a soft shoulder, shared by every star. Written into the
    /// red and the alpha channel alike so it reads correctly whichever one the
    /// opacity semantic samples, and left mipmapped because these quads are only
    /// a few pixels across.
    private static func makeDotTexture() async -> TextureResource {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for row in 0..<size {
            for column in 0..<size {
                let x = (Double(column) + 0.5) / Double(size) * 2 - 1
                let y = (Double(row) + 0.5) / Double(size) * 2 - 1
                let distance = (x * x + y * y).squareRoot()
                let shoulder = min(max((distance - 0.7) / 0.3, 0), 1)
                let value = 1 - shoulder * shoulder * (3 - 2 * shoulder)
                let level = UInt8(clamping: Int((value * 255).rounded()))
                let offset = (row * size + column) * 4
                pixels[offset] = level
                pixels[offset + 1] = level
                pixels[offset + 2] = level
                pixels[offset + 3] = level
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: [
                .byteOrder32Big,
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            ],
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
        return try! await TextureResource(
            image: image,
            withName: "EarthflightStarDot",
            options: TextureResource.CreateOptions(
                semantic: PhysicallyBasedMaterial.Opacity.textureSemantic
            )
        )
    }

    private static func makeBanks(dotTexture: TextureResource) -> [ModelEntity] {
        let bankCount = EarthflightTuning.starTwinklePeriodsSeconds.count
        // A fixed seed, so the same sky comes back every launch.
        var random = StarRandom(seed: 0x5ea5_7a25_0ea1_7455)
        var positions = [[SIMD3<Float>]](repeating: [], count: bankCount)
        var normals = [[SIMD3<Float>]](repeating: [], count: bankCount)
        var textureCoordinates = [[SIMD2<Float>]](repeating: [], count: bankCount)
        var indices = [[UInt32]](repeating: [], count: bankCount)
        let radius = EarthflightTuning.skyDomeRadiusMeters

        for star in 0..<EarthflightTuning.starCount {
            // Spreading evenly in the cosine of the polar angle gives a uniform
            // sphere. Picking two angles instead would crowd the poles.
            let cosinePolar = 2 * random.unitInterval() - 1
            let ringRadius = (1 - cosinePolar * cosinePolar).squareRoot()
            let azimuth = 2 * Double.pi * random.unitInterval()
            let direction = SIMD3<Float>(
                Float(ringRadius * cos(azimuth)),
                Float(cosinePolar),
                Float(ringRadius * sin(azimuth))
            )

            // Squaring the sample leaves most stars at the smallest size so a few
            // large ones stand out. Size is the only per-star brightness
            // variation a shared material can carry.
            let sizeSample = random.unitInterval()
            let angularSizeDegrees = EarthflightTuning.starSmallestAngularSizeDegrees +
                (EarthflightTuning.starLargestAngularSizeDegrees -
                    EarthflightTuning.starSmallestAngularSizeDegrees) * sizeSample * sizeSample
            let halfSize = radius * Float(angularSizeDegrees * .pi / 180 / 2)

            // Each quad lies tangent to the sphere, so it always faces the craft
            // at the centre without a billboard component per star.
            let reference: SIMD3<Float> = abs(direction.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
            let right = simd_normalize(simd_cross(reference, direction))
            let up = simd_cross(direction, right)
            let centre = direction * radius

            let bank = star % bankCount
            let base = UInt32(positions[bank].count)
            positions[bank].append(contentsOf: [
                centre - right * halfSize - up * halfSize,
                centre + right * halfSize - up * halfSize,
                centre + right * halfSize + up * halfSize,
                centre - right * halfSize + up * halfSize
            ])
            normals[bank].append(contentsOf: repeatElement(-direction, count: 4))
            textureCoordinates[bank].append(contentsOf: [[0, 0], [1, 0], [1, 1], [0, 1]])
            indices[bank].append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }

        var material = UnlitMaterial(color: .white)
        material.blending = .transparent(opacity: .init(scale: 1, texture: .init(dotTexture)))
        // A quad that always faces the viewer needs no winding.
        material.faceCulling = .none

        return (0..<bankCount).map { bank in
            var descriptor = MeshDescriptor(name: "EarthflightStars\(bank)")
            descriptor.positions = MeshBuffer(positions[bank])
            descriptor.normals = MeshBuffer(normals[bank])
            descriptor.textureCoordinates = MeshBuffer(textureCoordinates[bank])
            descriptor.primitives = .triangles(indices[bank])
            return ModelEntity(
                mesh: try! .generate(from: [descriptor]),
                materials: [material]
            )
        }
    }
}
