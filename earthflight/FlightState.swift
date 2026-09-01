import Foundation
import RealityKit
import simd

@MainActor
final class FlightState {
    private static let initialLocalEarthPosition = SIMD3<Double>(0, 1.5, 0)

    // Fixed-London RealityKit local metres: x=east, y=up, z=-north.
    // Keep the persistent craft position in Double; conversion to Float happens
    // only when RealityKit's Earth-root matrix is produced.
    private(set) var localEarthPosition = initialLocalEarthPosition
    var position: SIMD3<Float> {
        SIMD3(
            Float(localEarthPosition.x),
            Float(localEarthPosition.y),
            Float(localEarthPosition.z)
        )
    }
    private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // Keep these as independent control state. The earlier incremental quaternion
    // composition let simultaneous yaw and pitch manifest as an apparent bank of
    // the rendered Earth even though no shoulder-roll input was present. Rebuilding
    // a basis from explicit angles below makes the important invariant obvious and
    // testable: heading and pitch never change the horizon's roll.
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

    func keepAlive(_ subscription: EventSubscription) {
        updateSubscription = subscription
    }

    // Physical right-stick click is an orientation escape hatch, not merely an
    // auto-level command: restore the exact launch heading, pitch and roll while
    // leaving the craft's global position and all movement inputs untouched.
    func resetView() {
        headingRadians = 0
        pitchRadians = 0
        rollRadians = 0
        rebuildOrientation()
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

        // Milestone 5 remains in the fixed London frame, so height above nearby
        // ground is an intentional approximation. Both horizontal and vertical
        // speed must derive from it: localEarthPosition.y is only displacement
        // from the 70 m London start and becomes misleading below that height.
        let approximateHeightAboveGround = max(
            0,
            EarthflightTuning.londonStartingHeightAboveGroundMeters +
                localEarthPosition.y - Self.initialLocalEarthPosition.y)
        let horizontalSpeed = Float(
            EarthflightTuning.minimumHorizontalSpeedMetersPerSecond +
                EarthflightTuning.horizontalHeightSpeedFactor * approximateHeightAboveGround
        ) * EarthflightTuning.horizontalSpeedMultiplier * (isBoosting ? 4 : 1)
        let localMovement = SIMD3<Float>(leftStick.x, 0, -leftStick.y)
        let horizontalMovement = orientation.act(localMovement) * horizontalSpeed * dt
        let lowAltitudeVerticalSpeed = min(
            EarthflightTuning.maximumLowAltitudeVerticalSpeedMetersPerSecond,
            EarthflightTuning.minimumVerticalSpeedMetersPerSecond +
                EarthflightTuning.lowAltitudeVerticalHeightSquaredSpeedFactor *
                approximateHeightAboveGround * approximateHeightAboveGround)
        let highAltitudeExcess = max(
            0,
            approximateHeightAboveGround -
                EarthflightTuning.highAltitudeVerticalSpeedThresholdMeters)
        let verticalSpeed = min(
            EarthflightTuning.maximumVerticalSpeedMetersPerSecond,
            lowAltitudeVerticalSpeed +
                EarthflightTuning.highAltitudeExcessSquaredSpeedFactor *
                highAltitudeExcess * highAltitudeExcess)
        let verticalInput = Double((isAscending ? 1 : 0) - (isDescending ? 1 : 0))
        let verticalBoost: Double = isBoosting ? 4 : 1
        let verticalMovement = SIMD3<Double>(
            0,
            verticalInput * verticalSpeed * verticalBoost * Double(dt),
            0
        )

        localEarthPosition += SIMD3<Double>(
            Double(horizontalMovement.x),
            Double(horizontalMovement.y),
            Double(horizontalMovement.z)
        ) + verticalMovement
    }

    private func rebuildOrientation() {
        // Build local-to-London axes directly from independent heading, pitch and
        // roll state. With roll == 0 the right axis has exactly zero world-up
        // component for every heading and pitch, so diagonal right-stick input
        // cannot bank the horizon. Only the shoulder-controlled roll angle can.
        // Do not replace this with per-frame yaw * orientation * pitch accumulation:
        // keeping roll implicit in one quaternion previously made this regression
        // difficult to see and allowed coupled right-stick input to deform the view.
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

    var localEarthFromCraftDelta: simd_float4x4 {
        let realityKitCraftPosition = SIMD3<Float>(
            Float(localEarthPosition.x),
            Float(localEarthPosition.y),
            Float(localEarthPosition.z)
        )
        let realityKitInitialCraftPosition = SIMD3<Float>(
            Float(Self.initialLocalEarthPosition.x),
            Float(Self.initialLocalEarthPosition.y),
            Float(Self.initialLocalEarthPosition.z)
        )
        let localEarthFromCraft = Transform(
            rotation: orientation,
            translation: realityKitCraftPosition
        ).matrix
        let localEarthFromInitialCraft = Transform(
            translation: realityKitInitialCraftPosition
        ).matrix
        // currentCraft * inverse(initialCraft) keeps rotations centred on the
        // initial eye-height craft position instead of incorrectly orbiting the
        // immersive world's floor origin.
        return localEarthFromCraft * localEarthFromInitialCraft.inverse
    }
}
