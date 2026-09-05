import CoreGraphics
import Foundation
import RealityKit
import UIKit
import simd

// A sprinkle of white points on a sphere just inside the sky dome. It is not a
// star map and does not try to be: the owner asked for a few twinkling pixels so
// that raw black space stops feeling empty. Three decisions carry the illusion,
// and none of them needs a shader.
//
//  * The field is anchored to ECEF rather than to the render frame. Render-local
//    axes rotate as the craft flies and jump by up to half a degree at every
//    50 km floating-origin rebase. The sky gradient is symmetric only about its
//    own up axis, so that rotation shifts it too, just too smoothly to notice;
//    a field of pinpoint stars would visibly pop instead. Countering the
//    rotation pins the stars to the Earth, the only fixed frame this
//    application has. The sky dome itself now carries its own rotation, to
//    current geodetic up rather than the render frame's fixed axes, so the
//    star field's parent is no longer the identity it once was and the
//    field's own orientation has to cancel that rotation too, or the stars
//    would rotate twice.
//  * Stars fade in with the same air mass that colours the sky. They are drowned
//    at ground level and full by about 40 km, with no separate mode or trigger.
//  * Twinkling is done in banks. The stars are split across several meshes whose
//    opacities breathe on different periods, which is far cheaper than animating
//    a thousand points individually and reads as shimmer. Real stars do not
//    twinkle in vacuum at all; this is a deliberate, requested untruth.
//
// Each star is a quad carrying one shared opacity texture: full brightness out to
// seven tenths of the way to the edge, then a smooth shoulder to nothing. Plain
// quads were visibly square on the headset. The texture also mipmaps, so a star
// only a pixel or two across is averaged down to a stable dim point instead of
// flickering as the head turns; that averaging costs roughly two fifths of its
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

    private struct Bank {
        let entity: ModelEntity
        var material: UnlitMaterial
    }

    private var banks: [Bank]
    /// Held so a twinkle only rewrites one float; the dot texture never changes.
    private var opacity: PhysicallyBasedMaterial.Opacity
    private var elapsedSeconds = 0.0

    init() async {
        opacity = .init(scale: 0, texture: .init(await Self.makeDotTexture()))
        banks = Self.makeBanks()
        entity.scale = .init(repeating: EarthflightTuning.starFieldRadiusFraction)
        for bank in banks {
            entity.addChild(bank.entity)
        }
    }

    /// Brightness of the sky at the zenith is what hides stars, and here that is
    /// the same air mass the gradient already uses: 1 at sea level, 0.03 at
    /// 30 km, effectively nothing past the Karman line. Stars start to show at
    /// around 15 km and are full by 40 km.
    nonisolated static func visibility(ellipsoidHeightMeters: Double) -> Double {
        let zenithAirMass = SkyAtmosphere.ray(
            heightMeters: ellipsoidHeightMeters,
            zenithAngleRadians: 0
        ).relativeAirMass
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
        // whole field keeps a thousand transparent quads out of the render for
        // all ordinary low flight.
        guard visibility > 0.004 else {
            entity.isEnabled = false
            return
        }
        entity.isEnabled = true
        elapsedSeconds += deltaTime

        // render-local -> ECEF cancels the render frame's own rotation, so a
        // direction in bank-local space always means the same direction on the
        // Earth. `skyOrientation.inverse` then cancels the parent dome's own
        // rotation to current geodetic up, which would otherwise be applied a
        // second time on top of this one. Scale set at construction survives
        // writing orientation.
        entity.orientation = skyOrientation.inverse * Self.earthAnchoredOrientation(
            renderLocalFromEcef: renderLocalFromEcef
        )

        for index in banks.indices {
            let period = EarthflightTuning.starTwinklePeriodsSeconds[index]
            // The per-bank phase offset only matters at launch, when every bank
            // would otherwise start at the same point of its cycle.
            let phase = 2 * Double.pi * (elapsedSeconds / period + Double(index) * 0.37)
            let twinkle = EarthflightTuning.starTwinkleBaseBrightness +
                EarthflightTuning.starTwinkleAmplitude * sin(phase)
            opacity.scale = Float(visibility * twinkle)
            banks[index].material.blending = .transparent(opacity: opacity)
            banks[index].entity.model?.materials = [banks[index].material]
        }
    }

    nonisolated static func earthAnchoredOrientation(
        renderLocalFromEcef: simd_double4x4
    ) -> simd_quatf {
        // The matrix is rigid, so its upper 3x3 is a rotation and survives the
        // cast to Float orthonormal to well within a pixel at this radius.
        FlightState.orientation(renderLocalFromEcef)
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

    private static func makeBanks() -> [Bank] {
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
            // large ones stand out. Angular size is the only per-star brightness
            // variation untextured geometry can carry.
            let sizeSample = random.unitInterval()
            let angularSizeDegrees = EarthflightTuning.starSmallestAngularSizeDegrees +
                (EarthflightTuning.starLargestAngularSizeDegrees -
                    EarthflightTuning.starSmallestAngularSizeDegrees) * sizeSample * sizeSample
            let halfSize = radius * Float(angularSizeDegrees * .pi / 180 / 2)

            // Each quad lies tangent to the sphere, so it always faces the craft
            // at the centre without needing a billboard component per star.
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

        return (0..<bankCount).map { bank in
            var descriptor = MeshDescriptor(name: "EarthflightStars\(bank)")
            descriptor.positions = MeshBuffer(positions[bank])
            descriptor.normals = MeshBuffer(normals[bank])
            descriptor.textureCoordinates = MeshBuffer(textureCoordinates[bank])
            descriptor.primitives = .triangles(indices[bank])
            var material = UnlitMaterial(color: .white)
            // Winding is not worth reasoning about for a quad that is already
            // guaranteed to face the viewer.
            material.faceCulling = .none
            return Bank(
                entity: ModelEntity(
                    mesh: try! .generate(from: [descriptor]),
                    materials: [material]
                ),
                material: material
            )
        }
    }
}
