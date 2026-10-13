import CoreGraphics
import Foundation
import RealityKit
import simd

// The sky is one inward-facing sphere centred on the craft, painted with a
// gradient that varies only with the angle from local up. One dimension is
// enough at any altitude: seen from a point above a sphere, the ground, the
// horizon ring and the atmosphere's bright limb are all rotationally symmetric
// about local up, so a circular gradient around the nadir and a vertical
// gradient on the texture are the same picture.
//
// Every altitude effect comes from one scalar per direction: the air mass along
// that ray, in sea-level vertical columns. There is no altitude term in the
// palette and no separate "space mode". Looking up from the ground gives 1 and
// blue. The ground horizon gives about 34 and a pale band, because a horizontal
// ray crosses far more air. Above the Karman line the upward air mass is about
// 0.00001 and the palette renders it black, while rays that graze the Earth
// still cross a long dense path and keep the thin bright rim seen from orbit.
// The horizon moves down the sky as the Earth shrinks without anything
// computing where it is: rays simply start reaching the ground.
//
// The gradient's zenith axis (the sphere's local +Y, where the texture's V=0
// row lands) has to track current geodetic up, not the render frame's own Y
// axis. Those coincide only where the render origin was last set; 50 km away
// they differ by about 0.45 degrees, then snap back at the next rebase.
// `SkyDome.update` therefore orients the entity to
// `FlightState.renderLocalFromCraftTangent`, which depends only on the craft's
// position, not on its attitude.

/// Geometry and density of the modelled atmosphere. These describe the world
/// rather than taste, so they are not in `EarthflightTuning`.
///
/// Nonisolated because it is pure arithmetic: the target defaults to MainActor
/// isolation, and building a gradient must not run on the render actor.
nonisolated enum SkyAtmosphere {
    /// One sphere is enough for a sky gradient. WGS84 flattening moves the
    /// horizon by hundredths of a degree, well under a texture row, and a single
    /// radius keeps "height above the modelled sphere" equal to the ellipsoid
    /// height `FlightState` already tracks.
    static let earthRadiusMeters = 6_371_000.0

    /// Air density falls by 1/e every scale height. This is the entire
    /// atmosphere model; everything else about the sky is geometry.
    static let densityScaleHeightMeters = 8_500.0

    /// Above this the modelled air is exp(-14) of sea level, which no texel can
    /// show. It also bounds every ray march.
    static let atmosphereTopMeters = 120_000.0

    /// Samples per ray. The march is centred on the ray's lowest point, where
    /// nearly all the density sits, so this is ample from the ground and from
    /// orbit alike.
    static let marchSampleCount = 64

    struct Ray {
        /// Air mass along the ray, in sea-level vertical columns.
        let relativeAirMass: Double
        /// True when the ray reaches the Earth instead of leaving the atmosphere.
        let reachesGround: Bool
    }

    /// Integrates the air along one ray leaving the craft.
    ///
    /// `zenithAngleRadians` is measured from local up: 0 is straight up, pi/2 is
    /// the local horizontal, pi is straight down.
    static func ray(
        heightMeters: Double,
        zenithAngleRadians: Double
    ) -> Ray {
        let earthRadius = earthRadiusMeters
        let topRadius = earthRadius + atmosphereTopMeters
        // Never let the eye sit below the modelled sphere. A negative height
        // would put the ground above the craft and paint the whole sky as
        // terrain; ellipsoid heights do go slightly negative over the sea.
        let eyeRadius = earthRadius + max(heightMeters, 1)
        let cosine = cos(zenithAngleRadians)
        let sine = sin(zenithAngleRadians)

        // Closest approach of the ray to the Earth's centre. `perigeeRadius` is
        // the radius there, and every sphere intersection below is the same
        // quadratic solved with that half-chord.
        let perigeeParameter = -eyeRadius * cosine
        let perigeeRadius = eyeRadius * sine

        let topHalfChordSquared = topRadius * topRadius - perigeeRadius * perigeeRadius
        guard topHalfChordSquared > 0 else {
            return Ray(relativeAirMass: 0, reachesGround: false)
        }
        let topHalfChord = topHalfChordSquared.squareRoot()
        let atmosphereExit = perigeeParameter + topHalfChord
        guard atmosphereExit > 0 else {
            return Ray(relativeAirMass: 0, reachesGround: false)
        }
        let atmosphereEntry = max(0, perigeeParameter - topHalfChord)

        let groundHalfChordSquared = earthRadius * earthRadius - perigeeRadius * perigeeRadius
        let groundHit = groundHalfChordSquared >= 0
            ? perigeeParameter - groundHalfChordSquared.squareRoot()
            : -1
        let reachesGround = groundHit >= 0
        let end = reachesGround ? min(groundHit, atmosphereExit) : atmosphereExit

        // Density is overwhelmingly concentrated around the ray's lowest point,
        // so march a window centred there rather than the whole chord, which for
        // a grazing ray is thousands of kilometres of near-vacuum. sqrt(2rH) is
        // the along-ray distance over which a grazing path climbs one scale
        // height; four of those cover the peak from the ground and from orbit.
        let lowestParameter = min(max(perigeeParameter, atmosphereEntry), end)
        let lowestRadius = radius(
            alongRay: lowestParameter,
            eyeRadius: eyeRadius,
            cosine: cosine
        )
        let halfWindow = 4 * (2 * lowestRadius * densityScaleHeightMeters).squareRoot()
        let start = max(atmosphereEntry, lowestParameter - halfWindow)
        let finish = min(end, lowestParameter + halfWindow)
        guard finish > start else {
            return Ray(relativeAirMass: 0, reachesGround: reachesGround)
        }

        let step = (finish - start) / Double(marchSampleCount)
        var density = 0.0
        for sample in 0..<marchSampleCount {
            let parameter = start + (Double(sample) + 0.5) * step
            let altitude = radius(
                alongRay: parameter,
                eyeRadius: eyeRadius,
                cosine: cosine
            ) - earthRadius
            density += exp(-altitude / densityScaleHeightMeters)
        }
        // Dividing by the scale height turns metres of sea-level-equivalent air
        // into vertical columns, so straight up from the ground reads 1.
        return Ray(
            relativeAirMass: density * step / densityScaleHeightMeters,
            reachesGround: reachesGround
        )
    }

    private static func radius(
        alongRay parameter: Double,
        eyeRadius: Double,
        cosine: Double
    ) -> Double {
        (eyeRadius * eyeRadius +
            parameter * parameter +
            2 * parameter * eyeRadius * cosine).squareRoot()
    }

    /// Closed form of `ray(heightMeters:zenithAngleRadians: 0).relativeAirMass`.
    /// Along a vertical ray altitude grows linearly with distance, so the
    /// exponential-density integral from the eye to the atmosphere top needs no
    /// march:
    ///
    /// airMass = exp(-h/H) * (1 - exp(-(T-h)/H))
    static func zenithAirMass(heightMeters: Double) -> Double {
        let height = max(heightMeters, 1)
        guard height < atmosphereTopMeters else {
            return 0
        }
        return exp(-height / densityScaleHeightMeters) *
            -expm1(-(atmosphereTopMeters - height) / densityScaleHeightMeters)
    }
}

/// The pure part of the sky: air mass and the palette in, texture pixels out.
/// Nonisolated for the same reason as `SkyAtmosphere`.
nonisolated enum SkyGradient {
    static let textureWidth = 32

    /// Scattered sky colour for one air mass, held past both ends of the palette.
    ///
    /// The palette is joined with a monotone cubic rather than straight lines.
    /// Straight lines change slope abruptly at every stop, and the eye turns a
    /// slope discontinuity into a visible band: at ground level the worst stop
    /// changed the slope of blue against angle by a factor of 8.6. A cubic
    /// removes the corner without moving the stops, so every tuned colour still
    /// appears exactly where it was tuned.
    static func scatteredColour(relativeAirMass: Double) -> SIMD3<Double> {
        let stops = EarthflightTuning.skyAirMassColourStops
        guard let upper = stops.firstIndex(where: { $0.airMass >= relativeAirMass }) else {
            return stops[stops.count - 1].colour
        }
        guard upper > 0 else {
            return stops[0].colour
        }
        let low = stops[upper - 1]
        let high = stops[upper]
        let span = high.airMass - low.airMass
        let fraction = (relativeAirMass - low.airMass) / span
        let squared = fraction * fraction
        let cubed = squared * fraction
        return low.colour * (2 * cubed - 3 * squared + 1) +
            stopTangents[upper - 1] * ((cubed - 2 * squared + fraction) * span) +
            high.colour * (-2 * cubed + 3 * squared) +
            stopTangents[upper] * ((cubed - squared) * span)
    }

    /// Fritsch-Carlson tangents for the palette, computed once. Averaging the
    /// neighbouring secants is what makes the curve smooth; the limiter is what
    /// stops the cubic bulging outside the two colours a segment joins, which
    /// matters here because the stops are spaced by orders of magnitude.
    private static let stopTangents: [SIMD3<Double>] = {
        let stops = EarthflightTuning.skyAirMassColourStops
        let secants = (0..<(stops.count - 1)).map { index in
            (stops[index + 1].colour - stops[index].colour) /
                (stops[index + 1].airMass - stops[index].airMass)
        }
        var tangents = [SIMD3<Double>](repeating: .zero, count: stops.count)
        tangents[0] = secants[0]
        tangents[stops.count - 1] = secants[stops.count - 2]
        for index in 1..<(stops.count - 1) {
            tangents[index] = (secants[index - 1] + secants[index]) / 2
        }
        for index in 0..<(stops.count - 1) {
            for channel in 0..<3 {
                let secant = secants[index][channel]
                guard secant != 0 else {
                    tangents[index][channel] = 0
                    tangents[index + 1][channel] = 0
                    continue
                }
                let start = tangents[index][channel] / secant
                let end = tangents[index + 1][channel] / secant
                let magnitude = (start * start + end * end).squareRoot()
                if magnitude > 3 {
                    tangents[index][channel] = 3 * start / magnitude * secant
                    tangents[index + 1][channel] = 3 * end / magnitude * secant
                }
            }
        }
        return tangents
    }()

    /// Colour along one ray. Sky rays show their scattered light against space;
    /// rays that reach the Earth show the terrain-gap fill with that same
    /// scattered light laid over it as haze. The two agree at the horizon,
    /// because a ray grazing it collects almost as much air as one just above,
    /// so the gradient crosses the horizon without a seam at any altitude.
    static func colour(heightMeters: Double, zenithAngleRadians: Double) -> SIMD3<Double> {
        let ray = SkyAtmosphere.ray(
            heightMeters: heightMeters,
            zenithAngleRadians: zenithAngleRadians
        )
        let scattered = scatteredColour(relativeAirMass: ray.relativeAirMass)
        guard ray.reachesGround else {
            return scattered
        }
        let haze = 1 - exp(
            -EarthflightTuning.skyGroundHazeFractionPerAirMass * ray.relativeAirMass
        )
        let ground = EarthflightTuning.skyGroundFillColour
        return ground + (scattered - ground) * haze
    }

    /// Tightly packed RGBA8 rows, top row at the zenith, which is where the
    /// generated sphere puts V = 0.
    static func pixels(heightMeters: Double, rowCount: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: textureWidth * rowCount * 4)
        let raysPerRow = raysPerRow(heightMeters: heightMeters)
        for row in 0..<rowCount {
            var averaged = SIMD3<Double>(repeating: 0)
            for ray in 0..<raysPerRow {
                let rowFraction = (Double(ray) + 0.5) / Double(raysPerRow)
                let zenithAngle = (Double(row) + rowFraction) / Double(rowCount) * .pi
                averaged += colour(
                    heightMeters: heightMeters,
                    zenithAngleRadians: zenithAngle
                )
            }
            averaged = averaged * (255 / Double(raysPerRow))
            for column in 0..<textureWidth {
                // One offset for all three channels, so the residue is a faint
                // grey speckle rather than coloured confetti.
                let offset = (row * textureWidth + column) * 4
                let noise = dither(row: row, column: column)
                pixels[offset] = byte(averaged.x, plus: noise)
                pixels[offset + 1] = byte(averaged.y, plus: noise)
                pixels[offset + 2] = byte(averaged.z, plus: noise)
            }
        }
        return pixels
    }

    /// Rays averaged per row. One is enough while the atmosphere's bright limb is
    /// wider than a texture row: about 1.8 degrees from low orbit and still 0.27
    /// from 10,000 km, against 0.088 per row. Beyond that it narrows past a row
    /// and has to be averaged, or it flickers between rows during a climb.
    static func raysPerRow(heightMeters: Double) -> Int {
        heightMeters > EarthflightTuning.skySupersampleHeightMeters
            ? EarthflightTuning.skyGradientRaysPerRow
            : 1
    }

    /// Plus or minus half a level, fixed per texel. Eight bits are not enough for
    /// a gradient this shallow: near the zenith the blue channel holds one value
    /// for over a hundred rows, and the eye finds the step where it finally
    /// changes. Scattering that step across a band of texels lets bilinear
    /// magnification and the eye average it back to the true colour. The offset
    /// is a hash of the texel rather than a fresh random number, so the pattern
    /// is identical in every rebuild and the sky cannot sparkle during a climb.
    private static func dither(row: Int, column: Int) -> Double {
        var hash = UInt64(row) &* 0x9e37_79b9_7f4a_7c15 &+
            UInt64(column) &* 0xc2b2_ae3d_27d4_eb4f
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 29
        return Double(hash >> 11) * 0x1p-53 - 0.5
    }

    private static func byte(_ scaledComponent: Double, plus noise: Double) -> UInt8 {
        UInt8(clamping: Int((scaledComponent + noise).rounded()))
    }

    /// sRGB, and no mipmaps: the dome is always magnified, one row covering
    /// about a twentieth of a degree, so mipmaps would only cost time, blur the
    /// thin limb and average the dither away.
    static func image(pixels: [UInt8], rowCount: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: textureWidth,
            height: rowCount,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: textureWidth * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: [
                .byteOrder32Big,
                CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            ],
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }

    static func image(heightMeters: Double, rowCount: Int) -> CGImage {
        image(
            pixels: pixels(heightMeters: heightMeters, rowCount: rowCount),
            rowCount: rowCount
        )
    }

    static let textureCreateOptions = TextureResource.CreateOptions(
        semantic: .color,
        mipmapsMode: .none
    )
}

/// Owns the sky sphere and keeps it matched to the craft's height.
@MainActor
final class SkyDome {
    let entity: ModelEntity
    // Stars live under the dome so that they inherit its craft-centred position
    // and its altitude-driven radius, and can never fall outside it.
    private let starField: StarField
    private let texture: TextureResource
    private var builtHeightMeters: Double
    /// The gradient rebuild in flight, if any. At most one runs at a time.
    private var rebuildTask: Task<Void, Never>?

    init(ellipsoidHeightMeters: Double) async {
        starField = await StarField()
        builtHeightMeters = ellipsoidHeightMeters
        texture = try! await TextureResource(
            image: SkyGradient.image(
                heightMeters: ellipsoidHeightMeters,
                rowCount: EarthflightTuning.skyGradientRowCount
            ),
            withName: "EarthflightSkyGradient",
            options: SkyGradient.textureCreateOptions
        )
        var material = UnlitMaterial(texture: texture)
        material.faceCulling = .front
        entity = ModelEntity(
            mesh: .generateSphere(radius: EarthflightTuning.skyDomeRadiusMeters),
            materials: [material]
        )
        applyRadius(ellipsoidHeightMeters: ellipsoidHeightMeters)
        entity.addChild(starField.entity)
    }

    /// The sphere has to stay outside everything Cesium can draw. The farthest
    /// visible point of the Earth is the horizon tangent point, sqrt(d^2 - R^2)
    /// away, so half again that distance clears the globe from any altitude.
    /// Near the ground that is small and the fixed radius wins; the dome starts
    /// growing at around 3,000 km, where the whole Earth begins to fit in view
    /// and would otherwise be hidden behind the sky.
    nonisolated static func radiusMeters(ellipsoidHeightMeters: Double) -> Double {
        let earthRadius = SkyAtmosphere.earthRadiusMeters
        let eyeRadius = earthRadius + max(ellipsoidHeightMeters, 0)
        let horizonDistance = (eyeRadius * eyeRadius - earthRadius * earthRadius).squareRoot()
        return max(Double(EarthflightTuning.skyDomeRadiusMeters), 1.5 * horizonDistance)
    }

    nonisolated static func needsRebuild(
        builtHeightMeters: Double,
        ellipsoidHeightMeters: Double
    ) -> Bool {
        let step = max(
            EarthflightTuning.skyRebuildHeightStepMeters,
            EarthflightTuning.skyRebuildHeightFraction * abs(builtHeightMeters)
        )
        return abs(ellipsoidHeightMeters - builtHeightMeters) > step
    }

    // The mesh keeps the fixed radius; scale is how the dome grows above it.
    private func applyRadius(ellipsoidHeightMeters: Double) {
        entity.scale = .init(repeating: Float(
            Self.radiusMeters(ellipsoidHeightMeters: ellipsoidHeightMeters) /
                Double(EarthflightTuning.skyDomeRadiusMeters)
        ))
    }

    func update(
        renderLocalPosition: SIMD3<Float>,
        renderLocalFromEcef: simd_double4x4,
        renderLocalFromCraftTangent: simd_double4x4,
        ellipsoidHeightMeters: Double,
        deltaTime: TimeInterval
    ) {
        // The dome shares the Earth root's rotation but stays centred on the
        // craft in the current render frame. Its own orientation then points
        // the gradient's zenith at current geodetic up; see the comment at the
        // top of this file.
        entity.position = renderLocalPosition
        let orientation = simd_quatf(rotationOf: renderLocalFromCraftTangent)
        entity.orientation = orientation
        applyRadius(ellipsoidHeightMeters: ellipsoidHeightMeters)
        starField.update(
            ellipsoidHeightMeters: ellipsoidHeightMeters,
            renderLocalFromEcef: renderLocalFromEcef,
            skyOrientation: orientation,
            deltaTime: deltaTime
        )

        // One rebuild at a time. Under full vertical boost the height threshold
        // alone would ask for a new gradient every frame or two; this throttles
        // it to whatever the device keeps up with.
        guard rebuildTask == nil,
              Self.needsRebuild(
                builtHeightMeters: builtHeightMeters,
                ellipsoidHeightMeters: ellipsoidHeightMeters
              ) else {
            return
        }
        rebuildTask = Task {
            defer { rebuildTask = nil }
            let rowCount = EarthflightTuning.skyGradientRowCount
            // Milliseconds of pure arithmetic, so off the render actor.
            let pixels = await Task.detached(priority: .userInitiated) {
                SkyGradient.pixels(heightMeters: ellipsoidHeightMeters, rowCount: rowCount)
            }.value
            // A session that has ended must not receive a late upload.
            guard !Task.isCancelled else { return }
            do {
                try await texture.replace(
                    using: SkyGradient.image(pixels: pixels, rowCount: rowCount),
                    options: SkyGradient.textureCreateOptions
                )
            } catch {
                // The old texture is still installed and still right for
                // `builtHeightMeters`, so a later frame simply tries again.
                print("SkyDome: gradient upload failed at \(ellipsoidHeightMeters) m: \(error)")
                return
            }
            guard !Task.isCancelled else { return }
            builtHeightMeters = ellipsoidHeightMeters
        }
    }

    /// Cancels any rebuild in flight. Safe to call when idle or twice.
    func stop() {
        rebuildTask?.cancel()
    }
}
