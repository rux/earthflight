import Foundation
import RealityKit
import UIKit
import simd

/// How the nose mark is drawn. A ring leaves whatever the craft is pointed at
/// visible through the middle; a filled disc covers it.
enum HeadUpDisplayCircleStyle {
    case outlineRing
    case filledDisc
}

/// What the `-` button steps through, in this order, starting with the marks.
enum HeadUpDisplayMode {
    case marks
    case marksAndAltimeter
    case hidden
}

/// Two marks that say where the craft is pointed and where level is: a ring on
/// the nose axis, and a bar lying in the local horizontal plane with a gap the
/// ring sits in. At launch the ring sits exactly in that gap. Pitch the nose
/// down and the ring goes down with it while the bar stays on the horizon; roll
/// and the bar tilts while the ring stays where it is.
///
/// A mark has a direction and a distance, and the two are settled separately.
///
///  * **Direction comes from the wearer's head.** The marks keep the craft's
///    orientation but hang from wherever the head is, so the ring is exactly
///    along the nose from the eyes however the wearer leans, and at any
///    distance. That is also the right point to mark: the world streams past
///    the wearer along the nose, so what lies along the nose *from the head* is
///    what the wearer is flying at. Following the head costs a frame or so of
///    tracking lag, which shows only as a slight swim of a near mark during a
///    fast lean.
///  * **Distance comes from the ground.** Each mark is drawn as far away as the
///    ground it covers: the ring where the nose meets the ground, the bar at
///    the horizon. The ground is taken as a sphere at the height last measured
///    below the craft, which costs nothing and is exact on flat ground; on
///    steep relief the ring can sit off the true surface. Distance changes
///    nothing one eye can see, because the marks are sized in angles. What it
///    sets is binocular depth, so the eyes can hold a mark and the ground
///    behind it at once. Giant mode is where that matters: the world is at
///    arm's length, and a mark left far away is seen double against it.
///
/// Both distances shrink with the world in giant mode, like the ground itself.
///
/// Everything lives in the craft's own frame, so the marks need the craft's
/// attitude and nothing else: no render frame, no floating origin, no ECEF.
/// Heading cancels out of `horizonOrientation` exactly, which is the geometric
/// statement of the fact that yawing does not move the horizon in the view.
///
/// The bar tracks *local horizontal*, not the true visible horizon, which dips
/// below it by `acos(R / (R + h))`: 0.35 degrees at the launch height, 1 degree
/// at 1 km, 10 degrees at 100 km, 30 degrees at 1,000 km. Tracking the true
/// horizon would hold the bar off the ring at startup and, higher up, draw a
/// straight line tangent to a small round limb. Local horizontal is what an
/// attitude indicator shows, and what "level" means here.
///
/// The marks ignore depth, so terrain never buries them. The altimeter is a
/// third, optional mark: a small reading of the height above the measured
/// ground, parented to the bar so it rides on the end of its right arm through
/// pitch and roll.
@MainActor
final class HeadUpDisplay {
    /// Parent of both marks, placed once at the craft's fixed pose in the
    /// immersive world. Enable or disable it to show or hide the whole display.
    let entity = Entity()

    // Both meshes are built one metre from their entity's origin, so an
    // entity's scale is its mark's distance in metres.
    private let ring: ModelEntity
    private let horizonBar: ModelEntity
    /// Placed at the outer end of the right arm, turned to face the wearer.
    private let altimeter = Entity()
    /// Offset within `altimeter` so the text's right edge meets the arm's end.
    private let altimeterText = ModelEntity()
    private let altimeterMaterial: UnlitMaterial
    private var mode = HeadUpDisplayMode.marks
    private var secondsUntilAltimeterRefresh = 0.0
    private var shownAltimeterReading = ""

    init() {
        let material = Self.material()
        ring = ModelEntity(mesh: Self.ringMesh(), materials: [material])
        horizonBar = ModelEntity(mesh: Self.horizonBarMesh(), materials: [material])
        // The text is a closed extruded solid. With no depth test its back face
        // would blend over its front and double the opacity, so cull it.
        var textMaterial = material
        textMaterial.faceCulling = .back
        altimeterMaterial = textMaterial

        entity.addChild(ring)
        entity.addChild(horizonBar)

        // A point on the same horizontal arc as the arm, so it stays on the
        // horizon. Rotating local +Z by minus the arc angle points it back at
        // the wearer, which is the way the text's front face looks.
        let armEndAngle = Float(
            (Self.horizonBarGapHalfAngleDegrees + EarthflightTuning.headUpDisplayHorizonBarArmLengthDegrees) *
                .pi / 180
        )
        altimeter.position = [sin(armEndAngle), 0, -cos(armEndAngle)]
        altimeter.orientation = simd_quatf(angle: -armEndAngle, axis: [0, 1, 0])
        altimeter.isEnabled = false
        altimeter.addChild(altimeterText)
        horizonBar.addChild(altimeter)
    }

    /// The physical `-` button, alongside the `+` that starts a Jump To.
    func cycleMode() {
        mode = switch mode {
        case .marks: .marksAndAltimeter
        case .marksAndAltimeter: .hidden
        case .hidden: .marks
        }
        // So the altimeter reads the moment it appears, not a refresh later.
        secondsUntilAltimeterRefresh = 0
    }

    /// `groundDistanceHeightMeters` places the marks and should change
    /// smoothly; `altimeterHeightMeters` is the reading. `headWorldPosition` is
    /// nil until the head has been tracked, and the craft's own position then
    /// stands in for it.
    ///
    /// The Jump To card and the gamepad warning are billboarded at the same
    /// azimuth a metre and a quarter ahead, and the marks ignore depth, so they
    /// would otherwise be drawn over their text. Hiding them while either is up
    /// is simpler than sorting them; without a gamepad there is no flying to
    /// mark anyway.
    func update(
        craftOrientation: simd_quatf,
        groundDistanceHeightMeters: Double,
        altimeterHeightMeters: Double,
        headWorldPosition: SIMD3<Float>?,
        worldScale: Double,
        isJumpToCardShown: Bool,
        isGamepadWarningShown: Bool,
        deltaTime: TimeInterval
    ) {
        entity.isEnabled = mode != .hidden && !isJumpToCardShown && !isGamepadWarningShown
        guard entity.isEnabled else {
            return
        }

        // Geodetic up in the craft's axes, where the nose is -Z. The head is
        // in room metres, which are `1 / worldScale` world metres each.
        let up = craftOrientation.inverse.act(SIMD3<Float>(0, 1, 0))
        let head = headWorldPosition.map { entity.convert(position: $0, from: nil) } ?? .zero
        let headHeightMeters = groundDistanceHeightMeters + Double(simd_dot(head, up)) / worldScale
        let noseDistance = worldScale * Self.groundDistanceMeters(
            heightMeters: headHeightMeters,
            sineOfElevation: Double(-up.z)
        )
        let horizonDistance = worldScale * Self.groundDistanceMeters(
            heightMeters: headHeightMeters,
            sineOfElevation: 0
        )
        ring.position = head
        ring.scale = .init(repeating: Float(noseDistance))
        horizonBar.position = head
        horizonBar.scale = .init(repeating: Float(horizonDistance))
        horizonBar.orientation = Self.horizonOrientation(craftOrientation: craftOrientation)

        altimeter.isEnabled = mode == .marksAndAltimeter
        guard altimeter.isEnabled else {
            return
        }
        secondsUntilAltimeterRefresh -= deltaTime
        guard secondsUntilAltimeterRefresh <= 0 else {
            return
        }
        secondsUntilAltimeterRefresh = EarthflightTuning.headUpDisplayAltimeterRefreshSeconds
        let reading = Self.altimeterReading(heightAboveGroundMeters: altimeterHeightMeters)
        if reading != shownAltimeterReading {
            shownAltimeterReading = reading
            showAltimeterReading(reading)
        }
    }

    /// Metres along a ray to the ground, or to the horizon when the ray clears
    /// it. The ground is a sphere of the Earth's radius `heightMeters` below
    /// the ray's start, and `sineOfElevation` is the ray's direction dotted
    /// with local up: -1 straight down, 0 level.
    ///
    /// The two cases meet at the ray that grazes the horizon, so a mark moves
    /// out to the horizon and stops there as the nose comes up, with no jump.
    nonisolated static func groundDistanceMeters(
        heightMeters: Double,
        sineOfElevation: Double
    ) -> Double {
        // A start at or below the ground has no horizon. One metre up gives
        // every ray an answer, as the sky's ray march does.
        let height = max(heightMeters, 1)
        let earthRadius = SkyAtmosphere.earthRadiusMeters
        let horizonDistanceSquared = height * (2 * earthRadius + height)
        // How far along the ray its closest approach to the Earth's centre is.
        let closestApproach = -(earthRadius + height) * sineOfElevation
        let reachesGround = closestApproach > 0 &&
            closestApproach * closestApproach >= horizonDistanceSquared
        return reachesGround
            ? closestApproach - (closestApproach * closestApproach - horizonDistanceSquared).squareRoot()
            : horizonDistanceSquared.squareRoot()
    }

    /// Whole metres, or whole kilometres from 10 km, where metres would be
    /// more digits than anyone reads.
    nonisolated static func altimeterReading(heightAboveGroundMeters: Double) -> String {
        abs(heightAboveGroundMeters) < 10_000
            ? "\(Int(heightAboveGroundMeters.rounded())) m"
            : "\(Int((heightAboveGroundMeters / 1_000).rounded())) km"
    }

    /// Rebuilds the text mesh, then sets its right edge on the arm's end and
    /// its lowest glyph the tuned gap above the arm's top edge.
    private func showAltimeterReading(_ reading: String) {
        // RealityKit takes a text mesh's font size in metres, and the system
        // font spaces its glyphs differently at different sizes. Six is the
        // size the altimeter was accepted at, so the mesh is built there and
        // scaled down to one metre's distance.
        let fontSize: CGFloat = 6
        let mesh = MeshResource.generateText(
            reading,
            extrusionDepth: Float(fontSize) / 100,
            font: .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        )
        let scale = Self.tangent(degrees: EarthflightTuning.headUpDisplayAltimeterTextHeightDegrees) /
            Float(fontSize)
        let armTop = Self.tangent(degrees: EarthflightTuning.headUpDisplayHorizonBarThicknessDegrees / 2)
        let gap = Self.tangent(degrees: EarthflightTuning.headUpDisplayAltimeterGapDegrees)
        altimeterText.model = ModelComponent(mesh: mesh, materials: [altimeterMaterial])
        altimeterText.scale = .init(repeating: scale)
        altimeterText.position = [-mesh.bounds.max.x * scale, armTop + gap - mesh.bounds.min.y * scale, 0]
    }

    /// Orientation of the horizon bar within the craft's frame, given the
    /// craft-local -> local-horizontal attitude. Only pitch and roll survive:
    /// the craft's geodetic up in craft coordinates is
    /// `(cos(pitch) sin(roll), cos(pitch) cos(roll), -sin(pitch))`, with no
    /// heading term at all.
    ///
    /// The projection cannot degenerate, because `advance` clamps pitch to
    /// `maximumPitchFromHorizonDegrees`; at 80 degrees the projected direction
    /// still has 17 per cent of its full length.
    nonisolated static func horizonOrientation(
        craftOrientation: simd_quatf
    ) -> simd_quatf {
        let up = craftOrientation.inverse.act(SIMD3<Float>(0, 1, 0))
        let nose = SIMD3<Float>(0, 0, -1)
        // Drop the nose's vertical component to get the point of the horizon the
        // bar's gap straddles. Nose down leaves it above the nose, which is
        // where the horizon actually is.
        let alongHorizon = simd_normalize(nose - simd_dot(nose, up) * up)
        let right = simd_cross(alongHorizon, up)
        return simd_quatf(simd_float3x3(columns: (right, up, -alongHorizon)))
    }

    /// Half the angular width of the bar's gap. Derived from the ring so the gap
    /// always fits the circle, with the tuned margin either side of it.
    nonisolated static var horizonBarGapHalfAngleDegrees: Double {
        EarthflightTuning.headUpDisplayCircleDiameterDegrees / 2 +
            EarthflightTuning.headUpDisplayHorizonBarGapMarginDegrees
    }

    /// A flat ring one metre down the nose axis, or a disc when the style asks
    /// for one. The stroke is measured radially in degrees, like everything
    /// else here.
    private static func ringMesh() -> MeshResource {
        let outerAngleDegrees = EarthflightTuning.headUpDisplayCircleDiameterDegrees / 2
        let outerRadius = tangent(degrees: outerAngleDegrees)
        let innerRadius: Float = switch EarthflightTuning.headUpDisplayCircleStyle {
        case .filledDisc:
            0
        case .outlineRing:
            tangent(degrees: max(0, outerAngleDegrees - EarthflightTuning.headUpDisplayCircleStrokeDegrees))
        }

        // 3.75 degree facets, whose largest departure from a true circle is
        // under a thousandth of the stroke width.
        let segmentCount = 96
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        if innerRadius <= 0 {
            positions.append([0, 0, -1])
            for segment in 0...segmentCount {
                positions.append(rimPoint(radius: outerRadius, segment: segment, of: segmentCount))
            }
            for segment in 0..<segmentCount {
                indices.append(contentsOf: [0, UInt32(segment) + 1, UInt32(segment) + 2])
            }
        } else {
            for segment in 0...segmentCount {
                positions.append(rimPoint(radius: innerRadius, segment: segment, of: segmentCount))
                positions.append(rimPoint(radius: outerRadius, segment: segment, of: segmentCount))
            }
            for segment in 0..<segmentCount {
                let quad = UInt32(segment) * 2
                indices.append(contentsOf: [quad, quad + 1, quad + 3, quad, quad + 3, quad + 2])
            }
        }

        var descriptor = MeshDescriptor(name: "EarthflightHeadUpDisplayRing")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return try! .generate(from: [descriptor])
    }

    /// Two arms either side of the gap, each an arc of the horizontal circle
    /// one metre around the origin. Every point on an arc therefore lies
    /// exactly on the horizon however long the arm is, where a flat bar would
    /// only touch it at the centre and drift above it towards the ends.
    private static func horizonBarMesh() -> MeshResource {
        let halfThickness = tangent(degrees: EarthflightTuning.headUpDisplayHorizonBarThicknessDegrees / 2)
        let gapAngle = Float(horizonBarGapHalfAngleDegrees * .pi / 180)
        let armAngle = Float(
            EarthflightTuning.headUpDisplayHorizonBarArmLengthDegrees * .pi / 180
        )
        let segmentCount = 12
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for side in [Float(-1), 1] {
            let base = UInt32(positions.count)
            for segment in 0...segmentCount {
                let angle = side * (gapAngle + armAngle * Float(segment) / Float(segmentCount))
                let alongHorizon = SIMD3<Float>(sin(angle), 0, -cos(angle))
                positions.append(alongHorizon - [0, halfThickness, 0])
                positions.append(alongHorizon + [0, halfThickness, 0])
            }
            for segment in 0..<segmentCount {
                let quad = base + UInt32(segment) * 2
                indices.append(contentsOf: [quad, quad + 1, quad + 3, quad, quad + 3, quad + 2])
            }
        }

        var descriptor = MeshDescriptor(name: "EarthflightHeadUpDisplayHorizon")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return try! .generate(from: [descriptor])
    }

    /// What an angle spans, in metres, one metre away.
    private static func tangent(degrees: Double) -> Float {
        Float(tan(degrees * .pi / 180))
    }

    private static func rimPoint(
        radius: Float,
        segment: Int,
        of segmentCount: Int
    ) -> SIMD3<Float> {
        let angle = 2 * Float.pi * Float(segment) / Float(segmentCount)
        return [radius * cos(angle), radius * sin(angle), -1]
    }

    private static func material() -> UnlitMaterial {
        let colour = EarthflightTuning.headUpDisplayColour
        var material = UnlitMaterial(color: UIColor(
            red: CGFloat(colour.x),
            green: CGFloat(colour.y),
            blue: CGFloat(colour.z),
            alpha: 1
        ))
        material.blending = .transparent(
            opacity: .init(scale: EarthflightTuning.headUpDisplayOpacity)
        )
        // A head-up display is drawn over the world rather than in it. Without
        // this the marks would vanish into the first hillside or tall building
        // between the wearer and the ground they mark.
        material.readsDepth = false
        material.writesDepth = false
        // Neither mark is a closed surface, so winding is not worth reasoning
        // about.
        material.faceCulling = .none
        return material
    }
}
