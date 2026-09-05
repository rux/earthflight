import Foundation

// Owner-editable feel and presentation values. These remain compile-time
// constants deliberately; Earthflight has no settings UI.
enum EarthflightTuning {
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

    // Cesium refuses to refine a parent until every child is ready to render, so
    // ground coming into view always has something coarse rather than briefly
    // nothing. Detail arrives a little later in exchange. This is the setting
    // for the momentary transparent tiles over ground not yet visited.
    static let forbidTileHoles = true

    // Keeping every ancestor of every selected tile on screen does cover the
    // holes Cesium leaves when it refines past children that have not arrived,
    // but it was measured on the device at up to 96 extra tiles against a render
    // set of 90 to 236, and it starved tile loading badly enough to be worse
    // than the gap it fixed. Left off, and left in place only because a narrower
    // version of the same idea may still be the answer.
    static let drawCoarseAncestorShell = false

    // Temporary bisection switch. False stops Earthflight hiding anything at
    // all, so geometry only accumulates. If the momentary transparent tiles
    // survive that, nothing Earthflight removes can be causing them and the gap
    // is entirely in Cesium's selection. Memory grows while it is off, so fly
    // briefly. Delete once the cause is settled.
    static let retireOutgoingTiles = true

    // Outgoing tiles are retired only after the render set has been fully
    // installed for this many consecutive scene updates. Disabling an entity
    // takes effect on the frame it happens, but a freshly attached one is not
    // necessarily drawn until RealityKit has taken it up, so retiring on the
    // first clear update leaves no frame where both LODs are on screen. `2` is
    // the smallest value that guarantees one such frame. Raise it if a gap
    // still shows; the cost is a slightly longer opaque overlap.
    static let tileRetirementOverlapUpdates: Int32 = 2

    // Temporary. Paints the sky dome flat magenta instead of its gradient, to
    // settle what the momentary flashes actually are. Magenta flashes mean
    // geometry really is missing and the dome is showing through. Black or grey
    // flashes mean the dome is not what is visible, the gap is not a coverage
    // problem at all, and ten rounds of coverage work were aimed at the wrong
    // thing. Set false and delete once that is settled.
    static let useDiagnosticSkyColour = false

    // Prints a one-line tile-retirement summary each second: render-set size,
    // how many selected tiles Earthflight cannot draw and why, how many are
    // awaiting installation, the shell size, and how many updates retired
    // anything. See the tile-transition dragons section in AGENTS.md for how to
    // read it and what it has already ruled out.
    static let logTileRetirementDiagnostics = false

    // MARK: - Presentation

    static let attributionTrailingInsetPoints: Double = 220
    static let skyDomeRadiusMeters: Float = 600_000
}
