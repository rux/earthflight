import Foundation

// Every owner-editable feel and presentation value. These are compile-time
// constants on purpose: there is no settings screen. Nonisolated because the
// target defaults to MainActor isolation and the sky gradient reads them from
// a background task.
nonisolated enum EarthflightTuning {
    // MARK: - Controller

    // Fraction of full stick travel ignored around centre. Past it, response
    // rises from zero, so there is no jump in speed at the edge.
    static let controllerDeadZone: Float = 0.12
    static let yawRateRadiansPerSecond: Float = 1.2
    static let pitchRateRadiansPerSecond: Float = 1.0
    static let rollRateRadiansPerSecond: Float = 0.45

    // MARK: - Flight

    // Stops right-stick pitch reaching vertical and flipping the craft over.
    static let maximumPitchFromHorizonDegrees: Float = 80

    // Speed scales with height above a reference ground level, which is set
    // this far below the craft at launch. It is not terrain height: altitude is
    // WGS84 ellipsoid height throughout.
    static let initialSpeedReferenceHeightMeters: Double = 70

    // Forward and strafe speed: minimum + factor * height, all times the
    // multiplier, which scales the whole curve without changing its shape.
    static let minimumHorizontalSpeedMetersPerSecond: Double = 3
    static let horizontalHeightSpeedFactor: Double = 0.3
    static let horizontalSpeedMultiplier: Double = 6
    static let boostMultiplier: Double = 4

    // How long left-stick and vertical movement take to fade out after
    // release, linearly. Zero disables the fade.
    static let movementReleaseDurationSeconds: Float = 0.5

    // The same fade on right-stick yaw and pitch, so a turn eases out instead
    // of stopping dead. Keep it much shorter than the movement fade: a long one
    // keeps the view turning after the stick is released, which reads as
    // overshoot rather than weight. Roll is not affected. Zero disables it.
    static let steeringReleaseDurationSeconds: Float = 0.15

    // Climb and descent speed, in two stages. Below the threshold a squared
    // curve, capped to keep city flight controllable; above it a second
    // squared term makes kilometres of height change practical.
    static let minimumVerticalSpeedMetersPerSecond: Double = 1
    static let lowAltitudeVerticalHeightSquaredSpeedFactor: Double = 1
    static let maximumLowAltitudeVerticalSpeedMetersPerSecond: Double = 100
    static let highAltitudeVerticalSpeedThresholdMeters: Double = 250
    static let highAltitudeExcessSquaredSpeedFactor: Double = 0.0015
    static let maximumVerticalSpeedMetersPerSecond: Double = 9_000

    // The one flight ceiling, the Moon's mean distance. Render-local positions
    // are Float: out here one unit in the last place is 47 m, and ten times
    // higher the globe itself comes apart. The vertical speed cap above is not
    // a ceiling, because pitching over and flying forward climbs at the
    // height-scaled horizontal speed, which crosses this in seconds; coming
    // back down the same way is as quick.
    static let maximumEllipsoidHeightMeters: Double = 384_400_000

    // MARK: - Jump To

    static let jumpHeightAboveGroundMeters: Double = 1_000

    // MARK: - Planetary precision

    // The render origin moves to the craft once it is this far away in ECEF.
    // A Float precision limit, not a feel setting.
    static let renderOriginRebaseDistanceMeters: Double = 50_000

    // MARK: - Tile detail

    // Cesium refines a tile until its geometric error would span fewer than
    // this many headset pixels. Lower is sharper and loads more: each halving
    // refines everything about one level further, roughly four times the
    // tiles. Cesium's own default is 16.
    static let maximumScreenSpaceErrorHeadsetPixels: Double = 42.5

    // What turns the figure above into an angle. The original M2 Vision Pro
    // shows about 34 pixels per degree. A fact about the device, not taste.
    static let headsetPixelsPerDegree: Double = 34

    // The cone, centred on where the head points, that Cesium selects tiles
    // for. Wider than the display so a quick head turn finds ground already
    // there; the 90 by 70 degrees once used left gaps at the edges of view.
    // Wider still loads ground that may never be seen. Keep each under 180.
    static let tileSelectionHorizontalFieldOfViewDegrees: Double = 120
    static let tileSelectionVerticalFieldOfViewDegrees: Double = 110

    // When more than this many of a tile's selected descendants are still
    // loading, Cesium shows the tile itself instead and loads it first. Lower
    // gets coarse ground on screen sooner after a turn; higher waits for more
    // of the detail. Cesium's default.
    static let loadingDescendantLimit: UInt32 = 20

    // Tile requests in flight at once. This limits loading, not what is shown
    // or cached.
    static let maximumSimultaneousTileLoads: UInt32 = 8

    // Cesium's in-memory tile cache, counted as decoded texels plus geometry.
    // RealityKit holds the texels Cesium counts here, as GPU textures with
    // mipmaps. Nothing is cached on disk.
    static let maximumCachedBytes: Int64 = 1024 * 1024 * 1024

    // Despite its documentation, in cesium-native 0.64 this only makes tiles
    // outside the view load and report upward. It is not a guarantee that a
    // refinement leaves no holes.
    static let forbidTileHoles = true

    // MARK: - Presentation

    static let attributionTrailingInsetPoints: Double = 220

    // MARK: - Giant mode

    // The wearer's size steps in doublings: D-pad up grows, down shrinks. Zero
    // is the one-to-one world and the floor. A count rather than a multiplier,
    // so every level is an exact power of two and shrinking always lands back
    // on exactly 1.
    //
    // Twelve doublings is 4,096: the eyes effectively span 258 m, and a city
    // two kilometres across becomes a half-metre model. Going further mostly
    // costs comfort, because the world closes in on the face: the ground has to
    // be half a metre times the multiplier below the craft before it is an
    // arm's length away, about two kilometres at this ceiling.
    static let maximumGiantDoublings = 12

    // Seconds per doubling. The size always changes at this rate, so two quick
    // presses take twice as long and arrive without a pause between them. Zero
    // steps instantly.
    static let giantSizeTransitionSeconds: Double = 0.25

    // MARK: - Head-up display

    // A ring on the nose axis and a bar in the local horizontal plane, with a
    // gap the ring sits in. Sizes are angles, not metres, because the marks
    // are far enough away to be effectively collimated; see `HeadUpDisplay`.
    static let headUpDisplayDistanceMeters: Float = 1_000
    static let headUpDisplayColour = SIMD3<Double>(0.12, 0.75, 0.12)
    static let headUpDisplayOpacity: Float = 0.45

    // A ring leaves what the nose points at visible through its middle. The
    // stroke is measured radially and ignored by a filled disc.
    static let headUpDisplayCircleStyle = HeadUpDisplayCircleStyle.outlineRing
    static let headUpDisplayCircleDiameterDegrees = 1.5
    static let headUpDisplayCircleStrokeDegrees = 0.1

    // Each arm covers this many degrees from the edge of the gap. The margin is
    // the clearance between the ring and each arm; the gap itself is derived
    // from the ring, so it always fits.
    static let headUpDisplayHorizonBarThicknessDegrees = 0.15
    static let headUpDisplayHorizonBarArmLengthDegrees = 5.0
    static let headUpDisplayHorizonBarGapMarginDegrees = 0.5

    // MARK: - Sky

    // Sky sphere radius while the craft is low. Above about 3,000 km the dome
    // grows so the whole globe stays inside it; see `SkyDome.radiusMeters`.
    static let skyDomeRadiusMeters: Float = 9_000_000

    // Rows in the sky gradient texture, each covering 180/rows degrees. 2,048
    // resolves the roughly two-degree bright limb seen from low orbit.
    static let skyGradientRowCount = 2_048

    // Rays averaged per row above the given height. From tens of thousands of
    // kilometres the bright limb is narrower than a row, and a single ray per
    // row would let it flicker between rows during a climb. Lower down the
    // extra rays only slow the rebuild.
    static let skyGradientRaysPerRow = 4
    static let skySupersampleHeightMeters: Double = 10_000_000

    // The gradient is rebuilt once the height has moved further than the
    // larger of these. They are deliberately small: 500 m was once used, and
    // climbing that far from 1,000 m moved some texels by 63 of 255 levels,
    // which showed as visible steps. At most one rebuild runs at a time, so the
    // frame rate, not these, is the real throttle.
    static let skyRebuildHeightStepMeters: Double = 25
    static let skyRebuildHeightFraction: Double = 0.0001

    // Painted where a ray reaches the Earth, so it shows only through gaps in
    // the streamed terrain. A dull sandy brown makes a brief gap less stark
    // than bare sky would.
    static let skyGroundFillColour = SIMD3<Double>(0.62, 0.56, 0.46)

    // Fraction of the ground fill that one sea-level column of air replaces
    // with haze, applied as 1 - exp(-fraction * airMass). About a tenth is
    // clear-air Rayleigh extinction: distant ground near the horizon crosses
    // tens of columns and fades into the horizon colour; ground a few hundred
    // metres below is barely touched.
    static let skyGroundHazeFractionPerAirMass: Double = 0.1

    // The colour of the sky against space, indexed by air mass in sea-level
    // vertical columns (see `SkyDome`). This table is the whole palette.
    //
    // Air mass 1 is the zenith from sea level and 45 the sea-level horizon:
    // the blue and the pale band at ground level. The rows below 1 take the sky
    // from that blue to black as the air above thins: the zenith reads about
    // 0.3 at 10 km, 0.03 at 30 km and 0.00001 at the Karman line. Nothing here
    // mentions altitude, because air mass already carries it. Stops are joined
    // smoothly and hold past both ends.
    static let skyAirMassColourStops: [(airMass: Double, colour: SIMD3<Double>)] = [
        (0.00, SIMD3(0.000, 0.000, 0.008)),
        (0.04, SIMD3(0.004, 0.012, 0.055)),
        (0.12, SIMD3(0.012, 0.055, 0.185)),
        (0.30, SIMD3(0.030, 0.150, 0.400)),
        (1.00, SIMD3(0.060, 0.320, 0.680)),
        (3.00, SIMD3(0.230, 0.520, 0.820)),
        (8.00, SIMD3(0.400, 0.680, 0.890)),
        (20.0, SIMD3(0.610, 0.790, 0.905)),
        (45.0, SIMD3(0.740, 0.840, 0.910))
    ]

    // MARK: - Stars

    // Points over the whole sphere; roughly an eighth are in view at a time.
    static let starCount = 900

    // Angular width of a star's quad. The soft dot inside fades out before the
    // edge, so a star looks about four fifths of these: one to three pixels on
    // the M2 Vision Pro. Hard-edged quads read as squares.
    static let starSmallestAngularSizeDegrees = 0.04
    static let starLargestAngularSizeDegrees = 0.10

    // Stars sit at this fraction of the dome's radius: inside the dome, and
    // beyond everything Cesium draws.
    static let starFieldRadiusFraction: Float = 0.95

    // One twinkle period per bank of stars; the count is the number of banks.
    // Periods that do not divide into one another keep the banks from falling
    // back into step. Much shorter periods strobe.
    static let starTwinklePeriodsSeconds: [Double] = [2.3, 3.1, 4.7, 5.9, 7.3, 8.9, 11.3, 13.7]

    // A bank's opacity swings between base minus amplitude and base plus
    // amplitude; keep the two summing to no more than one. The base is high
    // because a whole bank breathes together, and a deep swing reads as banks
    // rather than twinkling. Mipmapping averages a one-pixel star's soft dot
    // down to about three fifths of white, which also argues for a high base.
    static let starTwinkleBaseBrightness = 0.80
    static let starTwinkleAmplitude = 0.20

    // Zenith air mass at which stars are dimmed by 1/e. Sea level reads 1 and
    // hides them completely; 30 km reads 0.03 and shows them almost fully.
    static let starZenithAirMassFade = 0.15
}
