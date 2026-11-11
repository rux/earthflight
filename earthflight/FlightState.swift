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

/// Both directions of one WGS84 tangent frame: X east, Y geodetic up, Z south,
/// metres from its origin. The floating render frame is one, and needs both.
/// Code that needs only local -> ECEF should call
/// `CesiumBridge.ecefFromLocalHorizontal` and skip the inverse.
struct TangentFrame {
    let ecefFromLocal: simd_double4x4
    let localFromEcef: simd_double4x4

    init(originEcef: SIMD3<Double>) {
        ecefFromLocal = CesiumBridge.ecefFromLocalHorizontal(origin: originEcef)
        localFromEcef = ecefFromLocal.inverse
    }
}

/// A linear fade after a two-axis control is let go, on each axis separately.
/// The output follows the control unless the control falls faster than the
/// fade allows; then the output falls in a straight line from where it was to
/// zero over `durationSeconds`. So letting go coasts, while easing back slowly
/// just follows the hand. A duration of zero disables it.
private struct ReleaseDecay {
    let durationSeconds: Float
    /// What each axis output last frame.
    private var output = SIMD2<Float>.zero
    /// How fast each axis may fall, in control units per second: set while
    /// following, so that a fade from there takes the whole duration.
    private var fallRate = SIMD2<Float>.zero

    init(durationSeconds: Float) {
        self.durationSeconds = durationSeconds
    }

    mutating func adjusted(_ input: SIMD2<Float>, deltaTime: Float) -> SIMD2<Float> {
        guard durationSeconds > 0 else {
            return input
        }
        for axis in 0..<2 {
            let fading = max(0, abs(output[axis]) - fallRate[axis] * deltaTime)
            if abs(input[axis]) >= fading {
                output[axis] = input[axis]
                fallRate[axis] = abs(input[axis]) / durationSeconds
            } else {
                // A let-go stick can rebound past centre; the Switch Pro's went
                // as far as +0.62 after a -1.0 strafe. A rebound weaker than the
                // fade so far is ignored like any other smaller input, so it can
                // neither kick the craft the wrong way nor cut the fade short.
                output[axis] = output[axis] < 0 ? -fading : fading
            }
        }
        return output
    }

    /// Forgets the fade in progress, so nothing coasts on from here.
    mutating func reset() {
        output = .zero
        fallRate = .zero
    }
}

/// The craft: where it is, which way it points, and the render frame around it.
@MainActor
final class FlightState {
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
    private(set) var craftEcefPosition: SIMD3<Double> {
        didSet { cartographic = Self.cartographic(of: craftEcefPosition) }
    }

    /// The same position as longitude, latitude and height, always derived
    /// from the ECEF one.
    private(set) var cartographic: CesiumCartographic

    var ellipsoidHeightMeters: Double { cartographic.ellipsoidHeightMeters }

    /// The floating render frame: right-handed, X east, Y geodetic up, Z south,
    /// metres, with its origin wherever launch, a jump or a rebase last put it.
    private var renderFrame: TangentFrame

    var ecefFromRenderLocal: simd_double4x4 { renderFrame.ecefFromLocal }
    var renderLocalFromEcef: simd_double4x4 { renderFrame.localFromEcef }

    /// The latest ground level below the craft: from the tiles under it, from
    /// Jump To's elevation, or at launch a fixed height below it.
    private var measuredGroundEllipsoidHeightMeters: Double

    /// Ground level for the speed curve. It follows the measured ground over
    /// `groundReferenceFollowSeconds` rather than stepping to it, so a change
    /// of ground underneath changes speed gradually.
    private var speedReferenceGroundEllipsoidHeightMeters: Double

    // Held as separate angles, and the attitude built from them, so that
    // heading and pitch can never create roll. Double, because carrying the
    // heading along each move adds changes too small for a Float.
    private var headingRadians = 0.0
    private var pitchRadians = 0.0
    private var rollRadians = 0.0

    private var movementRelease = ReleaseDecay(
        durationSeconds: EarthflightTuning.movementReleaseDurationSeconds
    )
    private var verticalRelease = ReleaseDecay(
        durationSeconds: EarthflightTuning.movementReleaseDurationSeconds
    )
    private var steeringRelease = ReleaseDecay(
        durationSeconds: EarthflightTuning.steeringReleaseDurationSeconds
    )

    /// The launch pose over London. The render origin starts 1.5 m below the
    /// craft: with `earthRoot` at identity on the first frame, that puts the
    /// craft, the wearer's eye point, at standing head height above the
    /// immersive space's floor origin.
    convenience init() {
        self.init(
            longitudeDegrees: -0.1278,
            latitudeDegrees: 51.5074,
            ellipsoidHeightMeters: 121.5,
            renderOriginEllipsoidHeightMeters: 120
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
        craftEcefPosition = CesiumBridge.ecefPosition(
            longitudeDegrees: longitudeDegrees,
            latitudeDegrees: latitudeDegrees,
            ellipsoidHeightMeters: ellipsoidHeightMeters
        )
        cartographic = Self.cartographic(of: craftEcefPosition)
        renderFrame = TangentFrame(originEcef: CesiumBridge.ecefPosition(
            longitudeDegrees: longitudeDegrees,
            latitudeDegrees: latitudeDegrees,
            ellipsoidHeightMeters: renderOriginEllipsoidHeightMeters ?? ellipsoidHeightMeters
        ))
        measuredGroundEllipsoidHeightMeters =
            cartographic.ellipsoidHeightMeters - EarthflightTuning.initialSpeedReferenceHeightMeters
        speedReferenceGroundEllipsoidHeightMeters = measuredGroundEllipsoidHeightMeters
    }

    private static func cartographic(of ecefPosition: SIMD3<Double>) -> CesiumCartographic {
        let cartographic = CesiumBridge.cartographic(ecefPosition: ecefPosition)
        precondition(
            cartographic.longitudeDegrees.isFinite &&
                cartographic.latitudeDegrees.isFinite &&
                cartographic.ellipsoidHeightMeters.isFinite,
            "Cesium could not convert craft ECEF to WGS84 cartographic coordinates"
        )
        return cartographic
    }

    // MARK: - Where the craft is

    var speedReferenceHeightMeters: Double {
        max(0, ellipsoidHeightMeters - speedReferenceGroundEllipsoidHeightMeters)
    }

    /// Negative when the craft has sunk below the last ground it measured.
    var heightAboveMeasuredGroundMeters: Double {
        ellipsoidHeightMeters - measuredGroundEllipsoidHeightMeters
    }

    var originDistanceMeters: Double {
        simd_length(craftEcefPosition - simd_make_double3(ecefFromRenderLocal.columns.3))
    }

    var renderLocalPosition: SIMD3<Double> {
        simd_make_double3(renderLocalFromEcef * SIMD4<Double>(craftEcefPosition, 1))
    }

    /// Craft-local -> local-horizontal attitude, from heading, then pitch, then
    /// roll. With roll at zero the right axis has no local-up component, even
    /// while yawing and pitching together.
    var orientation: simd_quatf {
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
        return simd_quatf(simd_float3x3(columns: (
            SIMD3<Float>(right),
            SIMD3<Float>(up),
            SIMD3<Float>(backward)
        )))
    }

    var renderLocalFromCraft: simd_double4x4 {
        // Craft-local -> current tangent frame applies the attitude; tangent ->
        // ECEF -> render-local then applies the Earth's curvature, once.
        renderLocalFromCraftTangent * simd_double4x4(simd_float4x4(orientation))
    }

    /// Render-local orientation of the craft's current tangent frame, with no
    /// attitude. The render frame's own axes match geodetic up only where the
    /// render origin was last set; 50 km away they are about 0.45 degrees out.
    /// Anything that wants up *here*, such as the sky's zenith, needs this.
    var renderLocalFromCraftTangent: simd_double4x4 {
        renderLocalFromEcef * CesiumBridge.ecefFromLocalHorizontal(origin: craftEcefPosition)
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

    // MARK: - Moving the craft

    /// A right-stick click: back to the launch attitude, wherever the craft is.
    func resetView() {
        headingRadians = 0
        pitchRadians = 0
        rollRadians = 0
        // A steering fade still running would turn the craft straight back off
        // level. Movement and its fade are left alone.
        steeringRelease.reset()
    }

    /// Moves the craft and its render frame to a new place in one step, level
    /// and facing north.
    func jump(
        longitudeDegrees: Double,
        latitudeDegrees: Double,
        groundEllipsoidHeightMeters: Double,
        heightAboveGroundMeters: Double
    ) {
        craftEcefPosition = CesiumBridge.ecefPosition(
            longitudeDegrees: longitudeDegrees,
            latitudeDegrees: latitudeDegrees,
            ellipsoidHeightMeters: groundEllipsoidHeightMeters + heightAboveGroundMeters
        )
        renderFrame = TangentFrame(originEcef: craftEcefPosition)
        // Both at once: the jump's own elevation is better than anything the
        // speed curve was following at the old place.
        measuredGroundEllipsoidHeightMeters = groundEllipsoidHeightMeters
        speedReferenceGroundEllipsoidHeightMeters = groundEllipsoidHeightMeters
        movementRelease.reset()
        verticalRelease.reset()
        resetView()
    }

    /// Takes one measurement of the ground straight below the craft, unless it
    /// is missing or came from a tile too coarse to trust at this height. Just
    /// after a jump the only tiles under the craft can be continent-sized, and
    /// one of those would undo the jump's own elevation. A rejected measurement
    /// leaves the last one standing.
    func measureGround(_ ground: CesiumGroundSample) {
        guard ground.ellipsoidHeightMeters.isFinite, ground.geometricErrorMeters.isFinite else {
            return
        }
        // The ray starts at the craft and points down, so the hit is never
        // above it.
        let heightAboveHit = ellipsoidHeightMeters - ground.ellipsoidHeightMeters
        guard ground.geometricErrorMeters <
            EarthflightTuning.maximumGroundTileErrorFractionOfHeight * heightAboveHit else { return }
        measuredGroundEllipsoidHeightMeters = ground.ellipsoidHeightMeters
    }

    /// Moves and turns the craft by one frame of input. `input` is nil when no
    /// controller is connected: one that has gone away can no longer report a
    /// release, so nothing it last reported may keep fading out.
    func advance(input: FlightInput?, deltaTime: TimeInterval) {
        guard let input else {
            movementRelease.reset()
            verticalRelease.reset()
            steeringRelease.reset()
            return
        }
        let dt = Float(min(deltaTime, 0.1))
        let movementStick = movementRelease.adjusted(input.leftStick, deltaTime: dt)
        // One axis; the second is always zero.
        let vertical = verticalRelease.adjusted([input.vertical, 0], deltaTime: dt).x
        // What fades on the right stick is the turn rate, so the craft eases
        // out of a turn.
        let steeringStick = steeringRelease.adjusted(input.rightStick, deltaTime: dt)

        headingRadians -= Double(steeringStick.x * EarthflightTuning.yawRateRadiansPerSecond * dt)
        // Positive stick y is pushed forward, which pitches the nose down.
        pitchRadians -= Double(steeringStick.y * EarthflightTuning.pitchRateRadiansPerSecond * dt)
        rollRadians -= Double(input.roll * EarthflightTuning.rollRateRadiansPerSecond * dt)
        headingRadians = Self.wrapped(headingRadians)
        rollRadians = Self.wrapped(rollRadians)
        let maximumPitch = Double(EarthflightTuning.maximumPitchFromHorizonDegrees) * .pi / 180
        pitchRadians = min(max(pitchRadians, -maximumPitch), maximumPitch)

        // An exponential approach, so the speed curve's ground never overshoots
        // and a new measurement is felt as a gradual change.
        let followSeconds = EarthflightTuning.groundReferenceFollowSeconds
        let followFraction = followSeconds > 0 ? 1 - exp(-Double(dt) / followSeconds) : 1
        speedReferenceGroundEllipsoidHeightMeters += followFraction *
            (measuredGroundEllipsoidHeightMeters - speedReferenceGroundEllipsoidHeightMeters)

        let boost = input.isBoosting ? EarthflightTuning.boostMultiplier : 1
        // The stick moves the craft along its own axes, pitch included.
        let attitudeMovement = SIMD3<Double>(
            orientation.act(SIMD3<Float>(movementStick.x, 0, -movementStick.y))
        ) * (horizontalSpeedMetersPerSecond * boost) * Double(dt)

        let verticalBoost = input.isBoosting || input.isVerticalBoosting
            ? EarthflightTuning.boostMultiplier
            : 1
        // The vertical buttons move along local up, whatever the attitude.
        let verticalMovement = SIMD3<Double>(
            0,
            Double(vertical) * verticalSpeedMetersPerSecond * verticalBoost * Double(dt),
            0
        )

        integrate(localDisplacement: attitudeMovement + verticalMovement)
    }

    /// Moves the render origin to the craft once it has drifted far enough for
    /// Float precision to matter.
    func rebaseIfNeeded() {
        if originDistanceMeters >= EarthflightTuning.renderOriginRebaseDistanceMeters {
            renderFrame = TangentFrame(originEcef: craftEcefPosition)
        }
    }

    /// Forward and strafe speed at full stick, before boost: it grows in
    /// proportion to height above the ground.
    private var horizontalSpeedMetersPerSecond: Double {
        (EarthflightTuning.minimumHorizontalSpeedMetersPerSecond +
            EarthflightTuning.horizontalHeightSpeedFactor * speedReferenceHeightMeters) *
            EarthflightTuning.horizontalSpeedMultiplier
    }

    /// Climb and descent speed, before boost: a capped squared curve near the
    /// ground, then a second squared term above the threshold.
    private var verticalSpeedMetersPerSecond: Double {
        let height = speedReferenceHeightMeters
        let lowAltitudeSpeed = min(
            EarthflightTuning.maximumLowAltitudeVerticalSpeedMetersPerSecond,
            EarthflightTuning.minimumVerticalSpeedMetersPerSecond +
                EarthflightTuning.lowAltitudeVerticalHeightSquaredSpeedFactor * height * height
        )
        let highAltitudeExcess = max(
            0,
            height - EarthflightTuning.highAltitudeVerticalSpeedThresholdMeters
        )
        return min(
            EarthflightTuning.maximumVerticalSpeedMetersPerSecond,
            lowAltitudeSpeed +
                EarthflightTuning.highAltitudeExcessSquaredSpeedFactor *
                highAltitudeExcess * highAltitudeExcess
        )
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
        var ecefFromLocal = CesiumBridge.ecefFromLocalHorizontal(origin: craftEcefPosition)
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
            let candidate = Self.cartographic(of: craftEcefPosition + horizontalStepEcef)
            craftEcefPosition = CesiumBridge.ecefPosition(
                longitudeDegrees: candidate.longitudeDegrees,
                latitudeDegrees: candidate.latitudeDegrees,
                ellipsoidHeightMeters: min(
                    ellipsoidHeightMeters + verticalStep,
                    EarthflightTuning.maximumEllipsoidHeightMeters
                )
            )
            ecefFromLocal = CesiumBridge.ecefFromLocalHorizontal(origin: craftEcefPosition)
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
}
