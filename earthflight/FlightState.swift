import Foundation
import simd

/// One frame of controller input, already in flight terms, with dead zones
/// applied.
struct FlightInput {
    /// x strafes right; y moves forward.
    var leftStick = SIMD2<Float>.zero
    /// x yaws right; y is the stick pushed forward, which pitches the nose down.
    var rightStick = SIMD2<Float>.zero
    /// +1 climbs and -1 descends, along local up.
    var vertical: Float = 0
    /// +1 rolls right and -1 rolls left.
    var roll: Float = 0
    var isBoosting = false
    var isVerticalBoosting = false
}

/// Both directions of one WGS84 tangent frame, for the floating render origin,
/// which needs both. Code that needs only local -> ECEF should call
/// `CesiumBridge.ecefFromLocalHorizontal` and skip the inverse.
struct EarthflightLocalFrame {
    let ecefFromLocal: simd_double4x4
    let localFromEcef: simd_double4x4

    init(originEcef: SIMD3<Double>) {
        ecefFromLocal = CesiumBridge.ecefFromLocalHorizontal(atEcefPosition: originEcef)
        localFromEcef = ecefFromLocal.inverse
    }
}

/// A linear fade after a two-axis control is released: the live input while it
/// is held, then a ramp from the strongest deliberate sample down to zero. Any
/// new input cancels a fade in progress. A duration of zero disables it.
private struct ReleaseDecay {
    private var strongestActiveInput = SIMD2<Float>.zero
    private var wasActive = false
    private var remainingSeconds: Float = 0

    mutating func adjusted(
        input: SIMD2<Float>,
        durationSeconds: Float,
        deltaTime: Float
    ) -> SIMD2<Float> {
        guard durationSeconds > 0 else {
            return input
        }
        if input != .zero {
            if !wasActive {
                strongestActiveInput = input
            } else {
                // A released Switch Pro stick rebounds past centre, as far as
                // +0.62 after a -1.0 strafe. Keeping the strongest sample on each
                // axis stops that rebound arming a fade in the wrong direction.
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
}

/// The craft: where it is, which way it points, and the render frame around it.
@MainActor
final class FlightState {
    static let launchLongitudeDegrees = -0.1278
    static let launchLatitudeDegrees = 51.5074
    static let launchCraftEllipsoidHeightMeters = 121.5
    static let launchRenderOriginEllipsoidHeightMeters = 120.0

    // A horizontal step must stay small as an angle at the Earth's centre, not
    // as a length, so the limit scales with geocentric radius: 10 km at the
    // surface, 1.6 milliradians anywhere. A flat 10 km limit let the step count
    // grow with altitude while speed grew with altitude too, and a pitched
    // climb once needed 899,106 Cesium conversions in a single frame.
    nonisolated private static let maximumSpatialIntegrationAngleRadians = 10_000.0 / 6_371_000.0

    /// Steps the horizontal integration takes for one frame's movement.
    nonisolated static func integrationStepCount(
        horizontalDistanceMeters: Double,
        geocentricRadiusMeters: Double
    ) -> Int {
        let stepLimit = maximumSpatialIntegrationAngleRadians * geocentricRadiusMeters
        return max(1, Int(ceil(horizontalDistanceMeters / stepLimit)))
    }

    /// The one authoritative position: WGS84 Earth-centred, Earth-fixed metres.
    /// The cartographic values below are derived from it.
    private(set) var craftEcefPosition: SIMD3<Double>
    private(set) var longitudeDegrees: Double
    private(set) var latitudeDegrees: Double
    private(set) var ellipsoidHeightMeters: Double

    /// The floating render frame: right-handed, X east, Y geodetic up, Z south,
    /// metres, with its origin wherever launch, a jump or a rebase last put it.
    private(set) var ecefFromRenderLocal: simd_double4x4
    private(set) var renderLocalFromEcef: simd_double4x4

    /// Ground level for the speed curve. Set at launch and by each jump, and
    /// not followed while flying away from there.
    private var speedReferenceGroundEllipsoidHeightMeters: Double

    /// Craft-local -> local-horizontal attitude, rebuilt from the three angles.
    private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // Held as separate angles, and the basis rebuilt from them, so that heading
    // and pitch can never create roll. Double, because carrying the heading
    // along each move adds changes too small for a Float.
    private var headingRadians = 0.0
    private var pitchRadians = 0.0
    private var rollRadians = 0.0

    private var movementRelease = ReleaseDecay()
    private var verticalRelease = ReleaseDecay()
    private var steeringRelease = ReleaseDecay()

    /// The launch pose over London. The render origin starts 1.5 m below the
    /// craft: with `earthRoot` at identity on the first frame, that puts the
    /// craft, the wearer's eye point, at standing head height above the
    /// immersive space's floor origin.
    convenience init() {
        self.init(
            longitudeDegrees: Self.launchLongitudeDegrees,
            latitudeDegrees: Self.launchLatitudeDegrees,
            ellipsoidHeightMeters: Self.launchCraftEllipsoidHeightMeters,
            renderOriginEllipsoidHeightMeters: Self.launchRenderOriginEllipsoidHeightMeters
        )
    }

    /// A level craft facing north. The render origin is at the craft unless a
    /// separate height is given.
    init(
        longitudeDegrees: Double,
        latitudeDegrees: Double,
        ellipsoidHeightMeters: Double,
        renderOriginEllipsoidHeightMeters: Double? = nil
    ) {
        craftEcefPosition = Self.ecefPosition(
            longitudeDegrees: longitudeDegrees,
            latitudeDegrees: latitudeDegrees,
            ellipsoidHeightMeters: ellipsoidHeightMeters
        )
        let renderOriginEcef = Self.ecefPosition(
            longitudeDegrees: longitudeDegrees,
            latitudeDegrees: latitudeDegrees,
            ellipsoidHeightMeters: renderOriginEllipsoidHeightMeters ?? ellipsoidHeightMeters
        )
        let renderFrame = EarthflightLocalFrame(originEcef: renderOriginEcef)
        ecefFromRenderLocal = renderFrame.ecefFromLocal
        renderLocalFromEcef = renderFrame.localFromEcef
        let cartographic = Self.cartographicDegrees(of: craftEcefPosition)
        self.longitudeDegrees = cartographic.x
        self.latitudeDegrees = cartographic.y
        self.ellipsoidHeightMeters = cartographic.z
        speedReferenceGroundEllipsoidHeightMeters =
            cartographic.z - EarthflightTuning.initialSpeedReferenceHeightMeters
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

    /// Longitude, latitude and ellipsoid height.
    private static func cartographicDegrees(of ecefPosition: SIMD3<Double>) -> SIMD3<Double> {
        let cartographic = CesiumBridge.cartographicDegrees(fromEcefPosition: ecefPosition)
        precondition(
            cartographic.x.isFinite && cartographic.y.isFinite && cartographic.z.isFinite,
            "Cesium could not convert craft ECEF to WGS84 cartographic coordinates"
        )
        return cartographic
    }

    var speedReferenceHeightMeters: Double {
        max(0, ellipsoidHeightMeters - speedReferenceGroundEllipsoidHeightMeters)
    }

    var originDistanceMeters: Double {
        simd_length(craftEcefPosition - simd_make_double3(ecefFromRenderLocal.columns.3))
    }

    var renderLocalPosition: SIMD3<Double> {
        simd_make_double3(renderLocalFromEcef * SIMD4<Double>(craftEcefPosition, 1))
    }

    var position: SIMD3<Float> {
        SIMD3<Float>(renderLocalPosition)
    }

    var renderLocalFromCraft: simd_double4x4 {
        // Craft-local -> current tangent frame applies the attitude; tangent ->
        // ECEF -> render-local then applies the Earth's curvature, once.
        renderLocalFromCraftTangent * localHorizontalFromCraft
    }

    /// Render-local orientation of the craft's current tangent frame, with no
    /// attitude. The render frame's own axes match geodetic up only where the
    /// render origin was last set; 50 km away they are about 0.45 degrees out.
    /// Anything that wants up *here*, such as the sky's zenith, needs this.
    var renderLocalFromCraftTangent: simd_double4x4 {
        renderLocalFromEcef * CesiumBridge.ecefFromLocalHorizontal(atEcefPosition: craftEcefPosition)
    }

    /// A right-stick click: back to the launch attitude, wherever the craft is.
    func resetView() {
        headingRadians = 0
        pitchRadians = 0
        rollRadians = 0
        // A steering fade still running would turn the craft straight back off
        // level. Movement and its fade are left alone.
        steeringRelease = ReleaseDecay()
        rebuildOrientation()
    }

    /// Moves the craft and its render frame to a new place in one step, level
    /// and facing north.
    func jump(
        longitudeDegrees: Double,
        latitudeDegrees: Double,
        groundEllipsoidHeightMeters: Double,
        heightAboveGroundMeters: Double
    ) {
        craftEcefPosition = Self.ecefPosition(
            longitudeDegrees: longitudeDegrees,
            latitudeDegrees: latitudeDegrees,
            ellipsoidHeightMeters: groundEllipsoidHeightMeters + heightAboveGroundMeters
        )
        updateCartographic()
        let frame = EarthflightLocalFrame(originEcef: craftEcefPosition)
        ecefFromRenderLocal = frame.ecefFromLocal
        renderLocalFromEcef = frame.localFromEcef
        speedReferenceGroundEllipsoidHeightMeters = groundEllipsoidHeightMeters
        movementRelease = ReleaseDecay()
        verticalRelease = ReleaseDecay()
        resetView()
    }

    /// Moves and turns the craft by one frame of input. `input` is nil when no
    /// controller is connected: one that has gone away can no longer report a
    /// release, so nothing it last reported may keep fading out.
    func advance(input: FlightInput?, deltaTime: TimeInterval) {
        guard let input else {
            movementRelease = ReleaseDecay()
            verticalRelease = ReleaseDecay()
            steeringRelease = ReleaseDecay()
            return
        }
        let dt = Float(min(deltaTime, 0.1))
        let movementStick = movementRelease.adjusted(
            input: input.leftStick,
            durationSeconds: EarthflightTuning.movementReleaseDurationSeconds,
            deltaTime: dt
        )
        // One axis; the second is always zero.
        let vertical = verticalRelease.adjusted(
            input: SIMD2(input.vertical, 0),
            durationSeconds: EarthflightTuning.movementReleaseDurationSeconds,
            deltaTime: dt
        ).x
        // What fades on the right stick is the turn rate, so the craft eases
        // out of a turn.
        let steeringStick = steeringRelease.adjusted(
            input: input.rightStick,
            durationSeconds: EarthflightTuning.steeringReleaseDurationSeconds,
            deltaTime: dt
        )

        headingRadians -= Double(steeringStick.x * EarthflightTuning.yawRateRadiansPerSecond * dt)
        // Positive stick y is pushed forward, which pitches the nose down.
        pitchRadians -= Double(steeringStick.y * EarthflightTuning.pitchRateRadiansPerSecond * dt)
        rollRadians -= Double(input.roll * EarthflightTuning.rollRateRadiansPerSecond * dt)
        headingRadians = Self.wrapped(headingRadians)
        rollRadians = Self.wrapped(rollRadians)
        let maximumPitch = Double(EarthflightTuning.maximumPitchFromHorizonDegrees) * .pi / 180
        pitchRadians = min(max(pitchRadians, -maximumPitch), maximumPitch)
        rebuildOrientation()

        let horizontalSpeed = (
            EarthflightTuning.minimumHorizontalSpeedMetersPerSecond +
                EarthflightTuning.horizontalHeightSpeedFactor * speedReferenceHeightMeters
        ) * EarthflightTuning.horizontalSpeedMultiplier *
            (input.isBoosting ? EarthflightTuning.boostMultiplier : 1)
        // The stick moves the craft along its own axes, pitch included.
        let attitudeMovement = SIMD3<Double>(
            orientation.act(SIMD3<Float>(movementStick.x, 0, -movementStick.y))
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
        let verticalBoost = input.isBoosting || input.isVerticalBoosting
            ? EarthflightTuning.boostMultiplier
            : 1
        // The vertical buttons move along local up, whatever the attitude.
        let verticalMovement = SIMD3<Double>(
            0,
            Double(vertical) * verticalSpeed * verticalBoost * Double(dt),
            0
        )

        integrate(localDisplacement: attitudeMovement + verticalMovement)
    }

    /// Moves the render origin to the craft once it has drifted far enough for
    /// Float precision to matter. True if it moved.
    func rebaseIfNeeded() -> Bool {
        guard originDistanceMeters >= EarthflightTuning.renderOriginRebaseDistanceMeters else {
            return false
        }
        let frame = EarthflightLocalFrame(originEcef: craftEcefPosition)
        ecefFromRenderLocal = frame.ecefFromLocal
        renderLocalFromEcef = frame.localFromEcef
        return true
    }

    /// Applies one frame's displacement, given in the craft's current tangent
    /// frame, and carries the heading along with it.
    private func integrate(localDisplacement: SIMD3<Double>) {
        // No displacement, no new position, exactly. Without this a hovering
        // craft would round-trip through Cesium's cartographic conversion every
        // frame and creep.
        guard localDisplacement != .zero else { return }

        let horizontalDistance = simd_length(
            SIMD2<Double>(localDisplacement.x, localDisplacement.z)
        )
        let stepCount = Self.integrationStepCount(
            horizontalDistanceMeters: horizontalDistance,
            geocentricRadiusMeters: simd_length(craftEcefPosition)
        )
        let horizontalStepLength = horizontalDistance / Double(stepCount)
        let verticalStep = localDisplacement.y / Double(stepCount)

        // The horizontal step and the craft's level forward direction travel as
        // ECEF vectors, and are laid back onto each new tangent plane after every
        // step. That is parallel transport: held straight, the craft flies a
        // great circle and keeps its heading relative to it. Holding a compass
        // heading instead flies a line of constant bearing, which spirals into a
        // pole, and flying due north bounces back and forth across the pole with
        // the world turning 180 degrees every frame.
        var ecefFromLocal = CesiumBridge.ecefFromLocalHorizontal(atEcefPosition: craftEcefPosition)
        var horizontalStepEcef = simd_make_double3(
            ecefFromLocal * SIMD4(localDisplacement.x, 0, localDisplacement.z, 0)
        ) / Double(stepCount)
        var forwardEcef = simd_make_double3(
            ecefFromLocal * SIMD4(-sin(headingRadians), 0, -cos(headingRadians), 0)
        )

        for _ in 0..<stepCount {
            // Horizontal motion along the tangent plane picks the next longitude
            // and latitude only. Height is then set explicitly, so stepping along
            // a tangent cannot add altitude. This is the one place flight height
            // is bounded.
            let candidate = Self.cartographicDegrees(of: craftEcefPosition + horizontalStepEcef)
            craftEcefPosition = Self.ecefPosition(
                longitudeDegrees: candidate.x,
                latitudeDegrees: candidate.y,
                ellipsoidHeightMeters: min(
                    ellipsoidHeightMeters + verticalStep,
                    EarthflightTuning.maximumEllipsoidHeightMeters
                )
            )
            updateCartographic()
            ecefFromLocal = CesiumBridge.ecefFromLocalHorizontal(atEcefPosition: craftEcefPosition)
            let up = simd_make_double3(ecefFromLocal.columns.1)
            horizontalStepEcef = Self.horizontal(horizontalStepEcef, up: up) * horizontalStepLength
            forwardEcef = Self.horizontal(forwardEcef, up: up)
        }

        guard horizontalDistance > 0 else { return }
        // Level forward is (-sin h, 0, -cos h) in the tangent frame, whose X is
        // east and Z south.
        let east = simd_make_double3(ecefFromLocal.columns.0)
        let south = simd_make_double3(ecefFromLocal.columns.2)
        headingRadians = atan2(-simd_dot(forwardEcef, east), -simd_dot(forwardEcef, south))
        rebuildOrientation()
    }

    /// The unit direction of `vector` once laid flat in the plane normal to `up`.
    /// Zero stays zero.
    private static func horizontal(_ vector: SIMD3<Double>, up: SIMD3<Double>) -> SIMD3<Double> {
        let flat = vector - simd_dot(vector, up) * up
        let length = simd_length(flat)
        return length > 0 ? flat / length : .zero
    }

    private static func wrapped(_ angleRadians: Double) -> Double {
        atan2(sin(angleRadians), cos(angleRadians))
    }

    private func updateCartographic() {
        let cartographic = Self.cartographicDegrees(of: craftEcefPosition)
        longitudeDegrees = cartographic.x
        latitudeDegrees = cartographic.y
        ellipsoidHeightMeters = cartographic.z
    }

    private func rebuildOrientation() {
        // Craft-local -> local-horizontal axes, from heading, then pitch, then
        // roll. With roll at zero the right axis has no local-up component, even
        // while yawing and pitching together.
        let headingCosine = cos(headingRadians)
        let headingSine = sin(headingRadians)
        let pitchCosine = cos(pitchRadians)
        let pitchSine = sin(pitchRadians)

        let levelRight = SIMD3<Double>(headingCosine, 0, -headingSine)
        let levelUp = SIMD3<Double>(
            headingSine * pitchSine,
            pitchCosine,
            headingCosine * pitchSine
        )
        let backward = SIMD3<Double>(
            headingSine * pitchCosine,
            -pitchSine,
            headingCosine * pitchCosine
        )

        let rollCosine = cos(rollRadians)
        let rollSine = sin(rollRadians)
        let right = levelRight * rollCosine + levelUp * rollSine
        let up = -levelRight * rollSine + levelUp * rollCosine
        orientation = simd_quatf(simd_float3x3(columns: (
            SIMD3<Float>(right),
            SIMD3<Float>(up),
            SIMD3<Float>(backward)
        )))
    }

    private var localHorizontalFromCraft: simd_double4x4 {
        simd_double4x4(simd_float4x4(orientation))
    }

    /// Render-local -> immersive world. The craft's fixed launch pose, then the
    /// inverse of where the craft now sits in the render frame. Assigning this to
    /// `earthRoot` moves the Earth under a camera that never moves.
    ///
    /// `worldScale` is giant mode. It belongs between the two terms, where it
    /// acts in the craft's own frame and so scales the world about the craft:
    /// the craft's world position, the head-up display placed on it, and every
    /// direction seen from it stay exactly as they were. See `GiantMode`.
    static func worldFromRenderLocal(
        worldFromCraftAtLaunch: simd_double4x4,
        renderLocalFromCraft: simd_double4x4,
        worldScale: Double = 1
    ) -> simd_double4x4 {
        let scale = simd_double4x4(diagonal: SIMD4<Double>(worldScale, worldScale, worldScale, 1))
        return worldFromCraftAtLaunch * scale * renderLocalFromCraft.inverse
    }
}
