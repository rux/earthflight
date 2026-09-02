import Foundation

// Owner-editable flight, render-origin, and Cesium selection values. These remain
// compile-time constants deliberately; Earthflight has no settings UI.
enum EarthflightTuning {
    // Prevent right-stick pitch from crossing vertical and inverting the craft.
    // Shoulder buttons remain the only source of roll.
    static let maximumPitchFromHorizonDegrees: Float = 80

    // Temporary speed reference preserving the accepted London launch feel. It
    // is not terrain height or AGL; Milestone 6 altitude is WGS84 ellipsoid height.
    static let initialSpeedReferenceHeightMeters: Double = 70
    // Flight-speed tuning lives together here deliberately. Milestone 8 should
    // adjust these constants instead of scattering new multipliers through
    // FlightState. All speeds are metres per second and heights are metres AGL.

    // Forward and strafe share this linear altitude curve. The final multiplier
    // changes the whole horizontal curve without changing its altitude response.
    static let minimumHorizontalSpeedMetersPerSecond: Double = 3
    static let horizontalHeightSpeedFactor: Double = 0.3
    static let horizontalSpeedMultiplier: Float = 6

    // Ascend/descend uses two stages. The existing low-altitude squared curve is
    // capped to preserve controllable city flight. Above the threshold, a second
    // squared term ramps rapidly, making kilometre-scale altitude changes practical.
    static let minimumVerticalSpeedMetersPerSecond: Double = 1
    static let lowAltitudeVerticalHeightSquaredSpeedFactor: Double = 1
    static let maximumLowAltitudeVerticalSpeedMetersPerSecond: Double = 100
    static let highAltitudeVerticalSpeedThresholdMeters: Double = 250
    static let highAltitudeExcessSquaredSpeedFactor: Double = 0.0015
    static let maximumVerticalSpeedMetersPerSecond: Double = 3_000

    // Rebase only when the global craft position has moved this Euclidean ECEF
    // distance from the current local render origin. This is a precision limit,
    // not a flight-feel setting.
    static let renderOriginRebaseDistanceMeters: Double = 50_000

    // Keep the opaque sky shell beyond the useful airline-altitude horizon.
    // A later milestone may derive this dynamically from ellipsoid height so the
    // dome stays beyond the geometric horizon without always using a large sphere.
    static let skyDomeRadiusMeters: Float = 400_000

    // Cesium refines until projected geometric error is below this many pixels.
    // Higher values reduce distant detail and requests; lower values add detail.
    static let maximumScreenSpaceError: Double = 16

    // Cesium's in-memory cache only. Raising this may reduce reloads after turning
    // back, but also increases memory pressure on the original M2 Vision Pro.
    static let maximumCachedBytes: Int64 = 512 * 1024 * 1024
}
