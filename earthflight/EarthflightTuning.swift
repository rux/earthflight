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
    static let lodTransitionsEnabled = true
    static let lodTransitionLengthSeconds: Float = 0.3

    // MARK: - Presentation

    static let attributionTrailingInsetPoints: Double = 220
    static let skyDomeRadiusMeters: Float = 600_000
}
