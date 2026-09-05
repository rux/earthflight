import Foundation

// Owner-editable feel and presentation values. These remain compile-time
// constants deliberately; Earthflight has no settings UI. The target defaults to
// MainActor isolation, so these constants say so explicitly: the sky gradient
// reads them from a background task.
nonisolated enum EarthflightTuning {
    // MARK: - Controller

    static let controllerDeadZone: Float = 0.12
    static let yawRateRadiansPerSecond: Float = 1.2
    static let pitchRateRadiansPerSecond: Float = 1.0
    static let rollRateRadiansPerSecond: Float = 0.45

    // MARK: - Flight

    // Prevent right-stick pitch from crossing vertical and inverting the craft.
    // Shoulder buttons remain the only source of roll.
    static let maximumPitchFromHorizonDegrees: Float = 80

    // Preserves the accepted London launch feel. It is not terrain height or
    // AGL; flight altitude is WGS84 ellipsoid height.
    static let initialSpeedReferenceHeightMeters: Double = 70

    // Forward and strafe share this linear altitude curve. The final multiplier
    // changes the whole horizontal curve without changing its altitude response.
    static let minimumHorizontalSpeedMetersPerSecond: Double = 3
    static let horizontalHeightSpeedFactor: Double = 0.3
    static let horizontalSpeedMultiplier: Float = 6
    static let boostMultiplier: Double = 4

    // Left-stick translation and ZL/ZR vertical movement decay linearly for this
    // long after release. Set to zero to disable the effect entirely; FlightState
    // then bypasses all release-decay state and calculations.
    static let movementReleaseDurationSeconds: Float = 0.5

    // Ascend/descend uses two stages. The existing low-altitude squared curve is
    // capped to preserve controllable city flight. Above the threshold, a second
    // squared term ramps rapidly, making kilometre-scale altitude changes practical.
    static let minimumVerticalSpeedMetersPerSecond: Double = 1
    static let lowAltitudeVerticalHeightSquaredSpeedFactor: Double = 1
    static let maximumLowAltitudeVerticalSpeedMetersPerSecond: Double = 100
    static let highAltitudeVerticalSpeedThresholdMeters: Double = 250
    static let highAltitudeExcessSquaredSpeedFactor: Double = 0.0015
    static let maximumVerticalSpeedMetersPerSecond: Double = 3_000

    // MARK: - Jump To

    /// A Jump To places the craft at this fixed clearance above converted ground.
    static let jumpHeightAboveGroundMeters: Double = 1_000

    // MARK: - Planetary precision

    // Rebase only when the global craft position has moved this Euclidean ECEF
    // distance from the current local render origin. This is a precision limit,
    // not a flight-feel setting.
    static let renderOriginRebaseDistanceMeters: Double = 50_000

    // MARK: - Tile selection and transition

    // Cesium refines until projected geometric error is below this many pixels.
    // Higher values make Cesium drop to coarser distant LODs earlier; lower
    // values preserve more detail. Nearby tiles still refine from projected error.
    static let maximumScreenSpaceError: Double = 24
    static let maximumSimultaneousTileLoads: UInt32 = 8

    // Cesium's transient in-memory cache only, not persistent storage. 1 GiB
    // trades additional memory pressure on the original M2 Vision Pro for fewer
    // reloads after looking away from a tile and back.
    static let maximumCachedBytes: Int64 = 1024 * 1024 * 1024
    // Earthflight no longer reads Cesium's fade list, so the transition period
    // buys it nothing, while enabling it permanently forces Cesium's frustum and
    // fog culling off. That both floods the selection with tiles right around
    // the globe and makes `forbidTileHoles` a no-op, since forbidHoles acts only
    // on culled tiles. Off restores both culling stages.
    static let lodTransitionsEnabled = false
    static let lodTransitionLengthSeconds: Float = 0.3

    // In cesium-native 0.64 this affects culled descendants only; it is not a
    // general replacement-coverage guarantee. Leave the accepted value alone.
    static let forbidTileHoles = true


    // MARK: - Presentation

    static let attributionTrailingInsetPoints: Double = 220

    // MARK: - Sky

    // Sky sphere radius while the craft is low. Above roughly 3,000 km the dome
    // grows instead, so the whole globe stays inside it; see SkyDome.radiusMeters.
    static let skyDomeRadiusMeters: Float = 9_000_000

    // Rows in the sky gradient texture. Each row covers 180/rows degrees, so
    // 2,048 resolves the roughly two-degree bright limb seen from low orbit.
    static let skyGradientRowCount = 2_048

    // Rays averaged per row, and the height above which that averaging is worth
    // paying for. Seen from tens of thousands of kilometres the bright limb
    // narrows to less than one row, and point sampling would let it flicker
    // between rows as the craft climbs; averaging turns it into a correctly
    // dimmed hairline instead. Lower down the limb is many rows wide and the
    // extra rays only slow the rebuild.
    static let skyGradientRaysPerRow = 4
    static let skySupersampleHeightMeters: Double = 10_000_000

    // Rebuild the gradient once the craft's height has moved further than the
    // larger of these. They are deliberately small: at 1,000 metres, climbing
    // 500 metres moved some texels by 63 of the 255 available levels, which is
    // the stepping the owner saw. The frame, not this threshold, is the real
    // throttle, because at most one rebuild starts per scene update. These
    // values only stop pointless work while drifting or hovering.
    static let skyRebuildHeightStepMeters: Double = 25
    static let skyRebuildHeightFraction: Double = 0.0001

    // Colour painted where a ray reaches the Earth. It shows only through gaps in
    // the streamed terrain, and stays the accepted dull sandy brown so a brief
    // gap is less stark than bare sky would be.
    static let skyGroundFillColour = SIMD3<Double>(0.62, 0.56, 0.46)

    // Fraction of the ground's colour that one sea-level vertical column of air
    // replaces with haze, applied as 1 - exp(-fraction * airMass). About a tenth
    // is clear-air Rayleigh extinction: distant ground near the horizon crosses
    // tens of columns and disappears into the horizon colour, while ground a few
    // hundred metres below the craft is barely touched.
    static let skyGroundHazeFractionPerAirMass: Double = 0.1

    // The scattered colour of the sky seen against space, indexed by air mass in
    // sea-level vertical columns (see SkyDome). This table is the whole palette.
    //
    // Air mass 1 is the zenith from sea level and 45 is the sea-level horizon, so
    // those two rows are the blue and the pale band the owner accepted at ground
    // level. The rows below 1 carry the sky from that blue down to black as the
    // air above thins: the zenith reads about 0.3 at 10 km, 0.03 at 30 km and
    // 0.00001 at the Karman line. Nothing here mentions altitude, because air mass
    // already carries it. Values interpolate linearly and hold past both ends.
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

    // Total points scattered over the whole sphere, so roughly an eighth of them
    // fall inside the field of view at any moment.
    static let starCount = 900

    // Angular width of a star's quad. The dot inside it is round and fades out
    // before the edge, so the star looks about four fifths of these figures: on
    // the original M2 Vision Pro's roughly 34 pixels per degree, one to three
    // pixels across. The first pass used hard-edged quads at 0.06 to 0.16 and
    // they read as visible squares, twice the size they wanted to be.
    static let starSmallestAngularSizeDegrees = 0.04
    static let starLargestAngularSizeDegrees = 0.10

    // Stars sit at this fraction of the sky dome's radius, which keeps them
    // inside it and therefore outside everything Cesium can draw.
    static let starFieldRadiusFraction: Float = 0.95

    // One period per bank, and the count of these is the number of banks. Values
    // that do not divide into each other keep the banks from drifting back into
    // step. Longer periods are a calmer sky; much shorter ones strobe.
    static let starTwinklePeriodsSeconds: [Double] = [2.3, 3.1, 4.7, 5.9, 7.3, 8.9, 11.3, 13.7]

    // A bank's opacity swings between base minus amplitude and base plus
    // amplitude. The base is deliberately high: every star in a bank breathes
    // together, so a deep swing would read as banks rather than as twinkling.
    // Mipmapping a one-pixel star averages its soft dot down to roughly three
    // fifths of full white, so the floor sits higher than it otherwise would.
    // Raise the base to brighten every star; raise the amplitude for a deeper
    // shimmer, keeping the two summing to no more than one.
    static let starTwinkleBaseBrightness = 0.80
    static let starTwinkleAmplitude = 0.20

    // Zenith air mass at which stars are dimmed by 1/e. Sea level reads 1 and
    // hides them completely; 30 km reads 0.03 and shows them almost fully.
    static let starZenithAirMassFade = 0.15
}
