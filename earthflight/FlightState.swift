import Foundation
import simd

/// Both directions of one WGS84 tangent frame. Build this only where both are
/// wanted, which is the floating render origin: launch, jump and rebase. Code
/// that needs the forward transform alone should call
/// `CesiumBridge.ecefFromLocalHorizontal` directly rather than build a frame and
/// drop `localFromEcef`. Measured on the M2 headset, that costs nothing in
/// Release -- whole-module optimisation already deletes the dead general 4x4
/// Double inverse -- so this is about not writing work nobody wants, and about
/// Debug builds, where nothing deletes it.
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

/// Linear release decay for one two-axis stick: the live input while the stick is
/// deflected, then a ramp from the strongest deliberate sample down to zero. Both
/// sticks want exactly this, including the recentre-rebound guard below, so they
/// share one implementation rather than keeping a copy each.
private struct StickReleaseDecay {
    private var strongestActiveInput = SIMD2<Float>(repeating: 0)
    private var wasActive = false
    private var remainingSeconds: Float = 0

    mutating func adjusted(
        input: SIMD2<Float>,
        durationSeconds: Float,
        deltaTime: Float
    ) -> SIMD2<Float> {
        if input != .zero {
            // Any new input cancels an in-flight release before becoming the
            // source gesture for the next distinct active-to-zero transition.
            if !wasActive {
                strongestActiveInput = input
            } else {
                // Physical testing showed Switch Pro recentering rebound as high
                // as +0.62 after a -1.0 left strafe, far beyond the dead zone.
                // Preserve the strongest deliberate sample on each axis rather
                // than arming a wrong-direction decay from that spring rebound.
                if abs(input.x) >= abs(strongestActiveInput.x) {
                    strongestActiveInput.x = input.x
                }
                if abs(input.y) >= abs(strongestActiveInput.y) {
                    strongestActiveInput.y = input.y
                }
            }
            wasActive = true
            remainingSeconds = 0
            return input
        }
        if wasActive {
            wasActive = false
            remainingSeconds = durationSeconds
        }
        guard remainingSeconds > 0 else {
            return .zero
        }

        remainingSeconds = max(0, remainingSeconds - deltaTime)
        return strongestActiveInput * (remainingSeconds / durationSeconds)
    }

    mutating func clear() {
        strongestActiveInput = .zero
        wasActive = false
        remainingSeconds = 0
    }
}

@MainActor
final class FlightState {
    static let launchLongitudeDegrees = -0.1278
    static let launchLatitudeDegrees = 51.5074
    static let launchBaseEllipsoidHeightMeters = 120.0
    static let launchCraftEllipsoidHeightMeters = 121.5

    // A tangent step keeps the simple projected horizontal integration well
    // conditioned. What has to stay small is the angle the step subtends at the
    // Earth's centre, not its length, so the limit scales with the craft's
    // geocentric radius: 10 km at the surface, and the same 1.6 milliradians from
    // any altitude. A flat 10 km made the step count grow with altitude without
    // bound, and horizontal speed grows with altitude too, so the two multiplied.
    // Nose down on full reverse stick turns that horizontal speed into climb and
    // the height feeds its own growth; ten seconds of it reached 899,106 Cesium
    // conversions in a single frame, which buried the frame rate and took the
    // controls, the tile updates and the sky's own update with it.
    nonisolated private static let maximumSpatialIntegrationAngleRadians = 10_000.0 / 6_371_000.0

    /// Steps the horizontal integration takes for one frame's tangent movement.
    /// Scaling with radius is what holds this flat instead of letting it grow
    /// with altitude; the invariant is worth a test of its own.
    nonisolated static func integrationStepCount(
        horizontalDistanceMeters: Double,
        geocentricRadiusMeters: Double
    ) -> Int {
        let stepLimit = maximumSpatialIntegrationAngleRadians * geocentricRadiusMeters
        return max(1, Int(ceil(horizontalDistanceMeters / stepLimit)))
    }

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
    var isVerticalBoosting = false

    private var leftStickRelease = StickReleaseDecay()
    private var rightStickRelease = StickReleaseDecay()
    private var lastActiveVerticalInput: Float = 0
    private var wasVerticalInputActive = false
    private var verticalReleaseRemainingSeconds: Float = 0

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
        // Nothing here wants the ECEF -> craft-tangent direction, so ask for the
        // one transform rather than build a frame and drop its inverse.
        CesiumBridge.ecefFromLocalHorizontal(atEcefPosition: craftEcefPosition)
    }

    var renderLocalFromCraft: simd_double4x4 {
        // craft-local -> current WGS84 tangent frame applies the accepted attitude;
        // tangent-local -> ECEF then ECEF -> render-local applies Earth curvature once.
        renderLocalFromEcef * ecefFromCraftLocalHorizontal * localHorizontalFromCraft
    }

    /// Render-local orientation of the craft's current geodetic tangent frame,
    /// with no attitude term. The render-local frame's own axes are fixed at
    /// whatever point last set the render origin (launch, jump or rebase), so
    /// they only match current geodetic up there; up to the 50 km rebase
    /// distance away they can differ by about 0.45 degrees. Anything that wants
    /// current geodetic up rather than origin-geodetic up, such as the sky
    /// dome's zenith axis, needs this rotation and not `renderLocalFromEcef` alone.
    var renderLocalFromCraftTangent: simd_double4x4 {
        renderLocalFromEcef * ecefFromCraftLocalHorizontal
    }

    /// Puts every controller input at rest without touching position or attitude.
    /// A controller that has gone away can no longer report a release, so its last
    /// values, and the release tails they would arm, must be dropped outright.
    func neutraliseInput() {
        leftStick = .zero
        rightStick = .zero
        isAscending = false
        isDescending = false
        isRollingLeft = false
        isRollingRight = false
        isBoosting = false
        isVerticalBoosting = false
        clearMovementRelease()
        rightStickRelease.clear()
    }

    // Physical right-stick click restores launch attitude while preserving the
    // sole global position and all movement input state.
    func resetView() {
        headingRadians = 0
        pitchRadians = 0
        rollRadians = 0
        // A residual steering tail would immediately turn the craft back off the
        // level attitude the reset just restored, so drop it here. Movement input
        // and its own release tail are deliberately preserved.
        rightStickRelease.clear()
        rebuildOrientation()
    }

    /// Atomically replaces the global craft position and floating render frame.
    /// Controller input remains intact, while heading, pitch, and roll reset through
    /// the same path as a physical right-stick click so every destination starts level.
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
        clearMovementRelease()
        resetView()
    }

    func advance(deltaTime: TimeInterval) {
        let dt = Float(min(deltaTime, 0.1))
        let rawVerticalInput = Float((isAscending ? 1 : 0) - (isDescending ? 1 : 0))
        let movementLeftStick: SIMD2<Float>
        let verticalInput: Float
        if EarthflightTuning.movementReleaseDurationSeconds > 0 {
            movementLeftStick = leftStickRelease.adjusted(
                input: leftStick,
                durationSeconds: EarthflightTuning.movementReleaseDurationSeconds,
                deltaTime: dt
            )
            verticalInput = releaseAdjustedVerticalInput(
                rawInput: rawVerticalInput,
                deltaTime: dt
            )
        } else {
            movementLeftStick = leftStick
            verticalInput = rawVerticalInput
        }

        // The right stick decays the same way, but it steers rather than moves:
        // what coasts is the turn rate, so the craft eases out of a yaw or pitch
        // instead of stopping dead. Keep this duration well under the movement
        // one; a long tail reads as the craft overshooting where it was aimed.
        // Roll is on buttons and is deliberately left alone.
        let steeringStick: SIMD2<Float>
        if EarthflightTuning.steeringReleaseDurationSeconds > 0 {
            steeringStick = rightStickRelease.adjusted(
                input: rightStick,
                durationSeconds: EarthflightTuning.steeringReleaseDurationSeconds,
                deltaTime: dt
            )
        } else {
            steeringStick = rightStick
        }

        headingRadians -= steeringStick.x * EarthflightTuning.yawRateRadiansPerSecond * dt
        // The verified Switch Pro Controller reports forward stick motion as
        // positive Y. Decreasing pitch pitches the craft nose down.
        pitchRadians -= steeringStick.y * EarthflightTuning.pitchRateRadiansPerSecond * dt
        let rollInput: Float = (isRollingRight ? 1 : 0) - (isRollingLeft ? 1 : 0)
        rollRadians -= rollInput * EarthflightTuning.rollRateRadiansPerSecond * dt

        headingRadians = atan2(sin(headingRadians), cos(headingRadians))
        rollRadians = atan2(sin(rollRadians), cos(rollRadians))
        let maximumPitch = EarthflightTuning.maximumPitchFromHorizonDegrees * .pi / 180
        pitchRadians = min(max(pitchRadians, -maximumPitch), maximumPitch)
        rebuildOrientation()

        let horizontalSpeed = (
            EarthflightTuning.minimumHorizontalSpeedMetersPerSecond +
                EarthflightTuning.horizontalHeightSpeedFactor * speedReferenceHeightMeters
        ) * Double(EarthflightTuning.horizontalSpeedMultiplier) *
            (isBoosting ? EarthflightTuning.boostMultiplier : 1)
        let craftMovement = orientation.act(
            SIMD3<Float>(movementLeftStick.x, 0, -movementLeftStick.y)
        )
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
        let verticalBoost = isBoosting || isVerticalBoosting
            ? EarthflightTuning.boostMultiplier
            : 1
        let geodeticVerticalMovement = SIMD3<Double>(
            0,
            Double(verticalInput) * verticalSpeed * verticalBoost * Double(dt),
            0
        )

        integrate(localDisplacement: attitudeMovement + geodeticVerticalMovement)
    }

    private func releaseAdjustedVerticalInput(
        rawInput: Float,
        deltaTime: Float
    ) -> Float {
        let duration = EarthflightTuning.movementReleaseDurationSeconds
        if rawInput != 0 {
            lastActiveVerticalInput = rawInput
            wasVerticalInputActive = true
            verticalReleaseRemainingSeconds = 0
            return rawInput
        }
        if wasVerticalInputActive {
            wasVerticalInputActive = false
            verticalReleaseRemainingSeconds = duration
        }
        guard verticalReleaseRemainingSeconds > 0 else {
            return 0
        }

        verticalReleaseRemainingSeconds = max(0, verticalReleaseRemainingSeconds - deltaTime)
        return lastActiveVerticalInput * (verticalReleaseRemainingSeconds / duration)
    }

    /// Movement only: the left stick and the vertical buttons. A right-stick
    /// click resets attitude and clears the steering tail separately, because it
    /// must not also cancel travel the owner is still asking for.
    private func clearMovementRelease() {
        leftStickRelease.clear()
        lastActiveVerticalInput = 0
        wasVerticalInputActive = false
        verticalReleaseRemainingSeconds = 0
    }

    @discardableResult
    func rebaseIfNeeded() -> Bool {
        guard originDistanceMeters >= EarthflightTuning.renderOriginRebaseDistanceMeters else {
            return false
        }
        let newFrame = EarthflightLocalFrame(originEcef: craftEcefPosition)
        ecefFromRenderLocal = newFrame.ecefFromLocal
        renderLocalFromEcef = newFrame.localFromEcef
        return true
    }

    private func integrate(localDisplacement: SIMD3<Double>) {
        // No displacement means no new position. The step below would otherwise
        // rebuild the tangent frame and round-trip the craft through Cesium's
        // cartographic conversion for nothing: on the M2 headset a hands-off
        // `advance` measured 397 ns before this guard and 68 ns after, every
        // frame the sticks are centred. The round trip is very nearly exact -- one
        // nanometre over a minute of idling -- but "very nearly" is a poor
        // contract for standing still, and this makes it exact by construction.
        guard localDisplacement != .zero else { return }

        let horizontalDistance = simd_length(
            SIMD2<Double>(localDisplacement.x, localDisplacement.z)
        )
        let stepCount = Self.integrationStepCount(
            horizontalDistanceMeters: horizontalDistance,
            geocentricRadiusMeters: simd_length(craftEcefPosition)
        )
        let step = localDisplacement / Double(stepCount)

        for _ in 0..<stepCount {
            let ecefFromCurrentLocal = CesiumBridge.ecefFromLocalHorizontal(
                atEcefPosition: craftEcefPosition
            )
            let horizontalCandidateEcef4 = ecefFromCurrentLocal *
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
            // The ceiling is the one place flight height is bounded; see the
            // tuning constant for why the world stops being drawable above it.
            craftEcefPosition = Self.ecefPosition(
                longitudeDegrees: candidateCartographic.x,
                latitudeDegrees: candidateCartographic.y,
                ellipsoidHeightMeters: min(
                    ellipsoidHeightMeters + step.y,
                    EarthflightTuning.maximumEllipsoidHeightMeters
                )
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

    // Pure casts between the Double planetary maths and RealityKit's Float
    // transforms. Nonisolated because the target defaults to MainActor isolation
    // and nothing about a matrix cast belongs on the render actor.
    nonisolated static func realityKitMatrix(_ matrix: simd_double4x4) -> simd_float4x4 {
        var result = matrix_identity_float4x4
        for column in 0..<4 {
            for row in 0..<4 {
                result[column][row] = Float(matrix[column][row])
            }
        }
        return result
    }

    nonisolated static func doubleMatrix(_ matrix: simd_float4x4) -> simd_double4x4 {
        var result = matrix_identity_double4x4
        for column in 0..<4 {
            for row in 0..<4 {
                result[column][row] = Double(matrix[column][row])
            }
        }
        return result
    }

    /// Rotation part of a rigid Double transform, as a Float quaternion. Shared
    /// by the sky dome, which orients itself to current geodetic up, and the
    /// star field, which cancels the render frame's rotation to stay ECEF-fixed.
    nonisolated static func orientation(_ matrix: simd_double4x4) -> simd_quatf {
        let float = realityKitMatrix(matrix)
        return simd_quatf(simd_float3x3(
            SIMD3(float.columns.0.x, float.columns.0.y, float.columns.0.z),
            SIMD3(float.columns.1.x, float.columns.1.y, float.columns.1.z),
            SIMD3(float.columns.2.x, float.columns.2.y, float.columns.2.z)
        ))
    }
}
