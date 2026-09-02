import Foundation
import RealityKit
import simd

struct EarthflightLocalFrame {
    let ecefFromLocal: simd_double4x4
    let localFromEcef: simd_double4x4

    init(originEcef: SIMD3<Double>) {
        ecefFromLocal = CesiumBridge.ecefFromLocalHorizontal(
            atEcefPosition: originEcef
        )
        localFromEcef = ecefFromLocal.inverse
    }
}

@MainActor
final class FlightState {
    static let launchLongitudeDegrees = -0.1278
    static let launchLatitudeDegrees = 51.5074
    static let launchBaseEllipsoidHeightMeters = 120.0
    static let launchCraftEllipsoidHeightMeters = 121.5

    // A 10 km tangent step keeps the simple projected horizontal integration
    // well conditioned even when altitude-scaled boost produces a large frame step.
    private static let maximumSpatialIntegrationStepMeters = 10_000.0

    // The single persistent global position: WGS84 Earth-centred, Earth-fixed
    // Cartesian metres in Double. Cartographic values below are derived snapshots.
    private(set) var craftEcefPosition: SIMD3<Double>
    private(set) var longitudeDegrees: Double
    private(set) var latitudeDegrees: Double
    private(set) var ellipsoidHeightMeters: Double

    // Current floating render frame. Local axes are right-handed X=east,
    // Y=geodetic up, Z=south; translations are metres. Both matrices stay Double.
    private(set) var ecefFromRenderLocal: simd_double4x4
    private(set) var renderLocalFromEcef: simd_double4x4
    private(set) var rebaseCount = 0

    /// Approximate local ground ellipsoid height used only by the accepted speed
    /// curve. It is not continuously sampled while flying away from this datum.
    private var speedReferenceGroundEllipsoidHeightMeters: Double

    private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // Keep these as independent control state. Rebuilding the basis makes the
    // accepted invariant explicit: heading and pitch never create incidental roll.
    private var headingRadians: Float = 0
    private var pitchRadians: Float = 0
    private var rollRadians: Float = 0

    var leftStick = SIMD2<Float>(repeating: 0)
    var rightStick = SIMD2<Float>(repeating: 0)
    var isAscending = false
    var isDescending = false
    var isRollingLeft = false
    var isRollingRight = false
    var isBoosting = false

    private var updateSubscription: EventSubscription?

    init() {
        let craftEcef = Self.ecefPosition(
            longitudeDegrees: Self.launchLongitudeDegrees,
            latitudeDegrees: Self.launchLatitudeDegrees,
            ellipsoidHeightMeters: Self.launchCraftEllipsoidHeightMeters
        )
        let renderOriginEcef = Self.ecefPosition(
            longitudeDegrees: Self.launchLongitudeDegrees,
            latitudeDegrees: Self.launchLatitudeDegrees,
            ellipsoidHeightMeters: Self.launchBaseEllipsoidHeightMeters
        )
        let renderFrame = EarthflightLocalFrame(originEcef: renderOriginEcef)
        craftEcefPosition = craftEcef
        longitudeDegrees = Self.launchLongitudeDegrees
        latitudeDegrees = Self.launchLatitudeDegrees
        ellipsoidHeightMeters = Self.launchCraftEllipsoidHeightMeters
        ecefFromRenderLocal = renderFrame.ecefFromLocal
        renderLocalFromEcef = renderFrame.localFromEcef
        speedReferenceGroundEllipsoidHeightMeters =
            Self.launchCraftEllipsoidHeightMeters - EarthflightTuning.initialSpeedReferenceHeightMeters
        updateCartographic()
    }

    init(
        longitudeDegrees: Double,
        latitudeDegrees: Double,
        ellipsoidHeightMeters: Double
    ) {
        let craftEcef = Self.ecefPosition(
            longitudeDegrees: longitudeDegrees,
            latitudeDegrees: latitudeDegrees,
            ellipsoidHeightMeters: ellipsoidHeightMeters
        )
        let renderFrame = EarthflightLocalFrame(originEcef: craftEcef)
        craftEcefPosition = craftEcef
        self.longitudeDegrees = longitudeDegrees
        self.latitudeDegrees = latitudeDegrees
        self.ellipsoidHeightMeters = ellipsoidHeightMeters
        ecefFromRenderLocal = renderFrame.ecefFromLocal
        renderLocalFromEcef = renderFrame.localFromEcef
        speedReferenceGroundEllipsoidHeightMeters =
            ellipsoidHeightMeters - EarthflightTuning.initialSpeedReferenceHeightMeters
        updateCartographic()
    }

    static func ecefPosition(
        longitudeDegrees: Double,
        latitudeDegrees: Double,
        ellipsoidHeightMeters: Double
    ) -> SIMD3<Double> {
        CesiumBridge.ecefPosition(
            withLongitudeDegrees: longitudeDegrees,
            latitudeDegrees: latitudeDegrees,
            ellipsoidHeightMeters: ellipsoidHeightMeters
        )
    }

    var speedReferenceHeightMeters: Double {
        max(
            0,
            ellipsoidHeightMeters - speedReferenceGroundEllipsoidHeightMeters
        )
    }

    var originDistanceMeters: Double {
        let origin = SIMD3<Double>(
            ecefFromRenderLocal.columns.3.x,
            ecefFromRenderLocal.columns.3.y,
            ecefFromRenderLocal.columns.3.z
        )
        return simd_length(craftEcefPosition - origin)
    }

    var renderLocalPosition: SIMD3<Double> {
        let position = renderLocalFromEcef * SIMD4<Double>(craftEcefPosition, 1)
        return SIMD3(position.x, position.y, position.z)
    }

    var position: SIMD3<Float> {
        let local = renderLocalPosition
        return SIMD3(Float(local.x), Float(local.y), Float(local.z))
    }

    var ecefFromCraftLocalHorizontal: simd_double4x4 {
        EarthflightLocalFrame(originEcef: craftEcefPosition).ecefFromLocal
    }

    var renderLocalFromCraft: simd_double4x4 {
        // craft-local -> current WGS84 tangent frame applies the accepted attitude;
        // tangent-local -> ECEF then ECEF -> render-local applies Earth curvature once.
        renderLocalFromEcef * ecefFromCraftLocalHorizontal * localHorizontalFromCraft
    }

    func keepAlive(_ subscription: EventSubscription) {
        updateSubscription = subscription
    }

    // Physical right-stick click restores launch attitude while preserving the
    // sole global position and all movement input state.
    func resetView() {
        headingRadians = 0
        pitchRadians = 0
        rollRadians = 0
        rebuildOrientation()
    }

    /// Atomically replaces the global craft position and floating render frame.
    /// The independent local heading, pitch, roll, and all controller input remain
    /// intact, so the craft has the same user-facing attitude at the destination.
    func jump(
        longitudeDegrees: Double,
        latitudeDegrees: Double,
        groundEllipsoidHeightMeters: Double,
        heightAboveGroundMeters: Double
    ) {
        let destinationEllipsoidHeightMeters =
            groundEllipsoidHeightMeters + heightAboveGroundMeters
        craftEcefPosition = Self.ecefPosition(
            longitudeDegrees: longitudeDegrees,
            latitudeDegrees: latitudeDegrees,
            ellipsoidHeightMeters: destinationEllipsoidHeightMeters
        )
        updateCartographic()
        let frame = EarthflightLocalFrame(originEcef: craftEcefPosition)
        ecefFromRenderLocal = frame.ecefFromLocal
        renderLocalFromEcef = frame.localFromEcef
        speedReferenceGroundEllipsoidHeightMeters = groundEllipsoidHeightMeters
        rebaseCount += 1
    }

    func advance(deltaTime: TimeInterval) {
        let dt = Float(min(deltaTime, 0.1))

        headingRadians -= rightStick.x * 1.2 * dt
        // The verified Switch Pro Controller reports forward stick motion as
        // positive Y. Decreasing pitch pitches the craft nose down.
        pitchRadians -= rightStick.y * 1.0 * dt
        let rollInput: Float = (isRollingRight ? 1 : 0) - (isRollingLeft ? 1 : 0)
        rollRadians -= rollInput * 0.45 * dt

        headingRadians = atan2(sin(headingRadians), cos(headingRadians))
        rollRadians = atan2(sin(rollRadians), cos(rollRadians))
        let maximumPitch = EarthflightTuning.maximumPitchFromHorizonDegrees * .pi / 180
        pitchRadians = min(max(pitchRadians, -maximumPitch), maximumPitch)
        rebuildOrientation()

        let horizontalSpeed = (
            EarthflightTuning.minimumHorizontalSpeedMetersPerSecond +
                EarthflightTuning.horizontalHeightSpeedFactor * speedReferenceHeightMeters
        ) * Double(EarthflightTuning.horizontalSpeedMultiplier) * (isBoosting ? 4 : 1)
        let craftMovement = orientation.act(SIMD3<Float>(leftStick.x, 0, -leftStick.y))
        let attitudeMovement = SIMD3<Double>(
            Double(craftMovement.x),
            Double(craftMovement.y),
            Double(craftMovement.z)
        ) * horizontalSpeed * Double(dt)

        let lowAltitudeVerticalSpeed = min(
            EarthflightTuning.maximumLowAltitudeVerticalSpeedMetersPerSecond,
            EarthflightTuning.minimumVerticalSpeedMetersPerSecond +
                EarthflightTuning.lowAltitudeVerticalHeightSquaredSpeedFactor *
                speedReferenceHeightMeters * speedReferenceHeightMeters
        )
        let highAltitudeExcess = max(
            0,
            speedReferenceHeightMeters - EarthflightTuning.highAltitudeVerticalSpeedThresholdMeters
        )
        let verticalSpeed = min(
            EarthflightTuning.maximumVerticalSpeedMetersPerSecond,
            lowAltitudeVerticalSpeed +
                EarthflightTuning.highAltitudeExcessSquaredSpeedFactor *
                highAltitudeExcess * highAltitudeExcess
        )
        let verticalInput = Double((isAscending ? 1 : 0) - (isDescending ? 1 : 0))
        let verticalBoost: Double = isBoosting ? 4 : 1
        let geodeticVerticalMovement = SIMD3<Double>(
            0,
            verticalInput * verticalSpeed * verticalBoost * Double(dt),
            0
        )

        integrate(localDisplacement: attitudeMovement + geodeticVerticalMovement)
    }

    @discardableResult
    func rebaseIfNeeded() -> Bool {
        guard originDistanceMeters >= EarthflightTuning.renderOriginRebaseDistanceMeters else {
            return false
        }
        let newFrame = EarthflightLocalFrame(originEcef: craftEcefPosition)
        ecefFromRenderLocal = newFrame.ecefFromLocal
        renderLocalFromEcef = newFrame.localFromEcef
        rebaseCount += 1
        return true
    }

    private func integrate(localDisplacement: SIMD3<Double>) {
        let horizontalDistance = simd_length(
            SIMD2<Double>(localDisplacement.x, localDisplacement.z)
        )
        let stepCount = max(
            1,
            Int(ceil(horizontalDistance / Self.maximumSpatialIntegrationStepMeters))
        )
        let step = localDisplacement / Double(stepCount)

        for _ in 0..<stepCount {
            let currentFrame = EarthflightLocalFrame(originEcef: craftEcefPosition)
            let horizontalCandidateEcef4 = currentFrame.ecefFromLocal *
                SIMD4<Double>(step.x, 0, step.z, 1)
            let horizontalCandidateEcef = SIMD3<Double>(
                horizontalCandidateEcef4.x,
                horizontalCandidateEcef4.y,
                horizontalCandidateEcef4.z
            )
            let candidateCartographic = CesiumBridge.cartographicDegrees(
                fromEcefPosition: horizontalCandidateEcef
            )
            precondition(
                candidateCartographic.x.isFinite &&
                    candidateCartographic.y.isFinite &&
                    candidateCartographic.z.isFinite,
                "Cesium could not convert the integrated ECEF craft position"
            )
            // Horizontal tangent motion selects the next lon/lat, then the ECEF
            // position is reconstructed at only the explicitly intended height.
            // This removes tangent-chord altitude gain while retaining pitch-induced
            // local-up motion and independent ZL/ZR geodetic vertical motion.
            craftEcefPosition = Self.ecefPosition(
                longitudeDegrees: candidateCartographic.x,
                latitudeDegrees: candidateCartographic.y,
                ellipsoidHeightMeters: ellipsoidHeightMeters + step.y
            )
            updateCartographic()
        }
    }

    private func updateCartographic() {
        let cartographic = CesiumBridge.cartographicDegrees(
            fromEcefPosition: craftEcefPosition
        )
        precondition(
            cartographic.x.isFinite && cartographic.y.isFinite && cartographic.z.isFinite,
            "Cesium could not derive WGS84 cartographic coordinates from craft ECEF"
        )
        longitudeDegrees = cartographic.x
        latitudeDegrees = cartographic.y
        ellipsoidHeightMeters = cartographic.z
    }

    private func rebuildOrientation() {
        // Build craft-local -> current local-horizontal axes from independent
        // heading, pitch, and roll. With roll == 0 the right axis has zero local-up
        // component, including during simultaneous yaw and pitch input.
        let headingCosine = cos(headingRadians)
        let headingSine = sin(headingRadians)
        let pitchCosine = cos(pitchRadians)
        let pitchSine = sin(pitchRadians)

        let levelRight = SIMD3<Float>(headingCosine, 0, -headingSine)
        let levelUp = SIMD3<Float>(
            headingSine * pitchSine,
            pitchCosine,
            headingCosine * pitchSine
        )
        let backward = SIMD3<Float>(
            headingSine * pitchCosine,
            -pitchSine,
            headingCosine * pitchCosine
        )

        let rollCosine = cos(rollRadians)
        let rollSine = sin(rollRadians)
        let right = levelRight * rollCosine + levelUp * rollSine
        let up = -levelRight * rollSine + levelUp * rollCosine
        orientation = simd_quatf(simd_float3x3(columns: (right, up, backward)))
    }

    private var localHorizontalFromCraft: simd_double4x4 {
        let rotation = simd_float3x3(orientation)
        var matrix = matrix_identity_double4x4
        for column in 0..<3 {
            for row in 0..<3 {
                matrix[column][row] = Double(rotation[column][row])
            }
        }
        return matrix
    }

    static func worldFromRenderLocal(
        worldFromCraftAtLaunch: simd_double4x4,
        renderLocalFromCraft: simd_double4x4
    ) -> simd_double4x4 {
        worldFromCraftAtLaunch * renderLocalFromCraft.inverse
    }

    static func realityKitMatrix(_ matrix: simd_double4x4) -> simd_float4x4 {
        var result = matrix_identity_float4x4
        for column in 0..<4 {
            for row in 0..<4 {
                result[column][row] = Float(matrix[column][row])
            }
        }
        return result
    }

    static func doubleMatrix(_ matrix: simd_float4x4) -> simd_double4x4 {
        var result = matrix_identity_double4x4
        for column in 0..<4 {
            for row in 0..<4 {
                result[column][row] = Double(matrix[column][row])
            }
        }
        return result
    }
}
