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
/// Three things make this far less work than it looks.
///
///  * The craft's pose in the immersive world never changes -- `earthRoot`
///    moves underneath it -- so "straight ahead" is a fixed world direction and
///    the ring is a static entity. Only the bar is touched per frame.
///  * Everything lives in the craft's own frame, so the bar needs the craft
///    attitude and nothing else: no render frame, no floating origin, no ECEF.
///    Heading cancels out of `horizonOrientation` exactly, which is the
///    geometric statement of the fact that yawing does not move the horizon in
///    the view.
///  * The bar tracks *local horizontal*, not the true visible horizon, which
///    dips below it by `acos(R / (R + h))`: 0.35 degrees at the launch height,
///    1 degree at 1 km, 10 degrees at 100 km, 30 degrees at 1,000 km. Tracking
///    the true horizon would hold the bar off the ring at startup and, higher
///    up, draw a straight line tangent to a small round limb. Local horizontal
///    is what an attitude indicator shows, and what "level" means here.
///
/// The marks are placed far away and sized in angles rather than metres. The
/// craft origin is a fixed world point but the wearer's head is not: at two
/// metres, leaning half a metre would swing the ring 14 degrees off the very
/// axis it exists to report. At a kilometre the same lean is 0.03 degrees and
/// the marks are effectively collimated, as a real head-up display is. They
/// also ignore depth, so terrain never buries them.
///
/// The altimeter is a third, optional mark: a small reading of the height above
/// the measured ground, parented to the bar so it rides on the end of its right
/// arm through pitch and roll.
@MainActor
final class HeadUpDisplay {
    /// Parent of both marks, placed once at the craft's fixed pose in the
    /// immersive world. Enable or disable it to show or hide the whole display.
    let entity = Entity()

    private let horizonBar: ModelEntity
    /// Placed at the outer end of the right arm, turned to face the craft.
    private let altimeter = Entity()
    /// Offset within `altimeter` so the text's right edge meets the arm's end.
    private let altimeterText = ModelEntity()
    private let altimeterMaterial: UnlitMaterial
    private var mode = HeadUpDisplayMode.marks
    private var secondsUntilAltimeterRefresh = 0.0
    private var shownAltimeterReading = ""

    init() {
        let distance = EarthflightTuning.headUpDisplayDistanceMeters
        let material = Self.material()
        let circle = ModelEntity(
            mesh: Self.circleMesh(distanceMeters: distance),
            materials: [material]
        )
        circle.position = [0, 0, -distance]
        horizonBar = ModelEntity(
            mesh: Self.horizonBarMesh(distanceMeters: distance),
            materials: [material]
        )
        // The text is a closed extruded solid. With no depth test its back face
        // would blend over its front and double the opacity, so cull it.
        var textMaterial = material
        textMaterial.faceCulling = .back
        altimeterMaterial = textMaterial

        entity.addChild(circle)
        entity.addChild(horizonBar)

        // A point on the same horizontal arc as the arm, so it stays on the
        // horizon. Rotating local +Z by minus the arc angle points it back at
        // the craft, which is the way the text's front face looks.
        let armEndAngle = Float(
            (Self.horizonBarGapHalfAngleDegrees + EarthflightTuning.headUpDisplayHorizonBarArmLengthDegrees) *
                .pi / 180
        )
        altimeter.position = [distance * sin(armEndAngle), 0, -distance * cos(armEndAngle)]
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

    /// The Jump To card is billboarded at the same azimuth a metre and a quarter
    /// ahead, and the marks ignore depth, so they would otherwise be drawn over
    /// its text. Hiding them while it is up is simpler than sorting them.
    func update(
        craftOrientation: simd_quatf,
        heightAboveGroundMeters: Double,
        isJumpToCardShown: Bool,
        deltaTime: TimeInterval
    ) {
        entity.isEnabled = mode != .hidden && !isJumpToCardShown
        guard entity.isEnabled else {
            return
        }

        horizonBar.orientation = Self.horizonOrientation(
            craftOrientation: craftOrientation
        )

        altimeter.isEnabled = mode == .marksAndAltimeter
        guard altimeter.isEnabled else {
            return
        }
        secondsUntilAltimeterRefresh -= deltaTime
        guard secondsUntilAltimeterRefresh <= 0 else {
            return
        }
        secondsUntilAltimeterRefresh = EarthflightTuning.headUpDisplayAltimeterRefreshSeconds
        let reading = Self.altimeterReading(heightAboveGroundMeters: heightAboveGroundMeters)
        if reading != shownAltimeterReading {
            shownAltimeterReading = reading
            showAltimeterReading(reading)
        }
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
        let distance = EarthflightTuning.headUpDisplayDistanceMeters
        // RealityKit takes a text mesh's font size in metres.
        let fontSize = Self.radius(
            distanceMeters: distance,
            angleDegrees: EarthflightTuning.headUpDisplayAltimeterTextHeightDegrees
        )
        let mesh = MeshResource.generateText(
            reading,
            extrusionDepth: fontSize / 100,
            font: .monospacedDigitSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        )
        altimeterText.model = ModelComponent(mesh: mesh, materials: [altimeterMaterial])
        let armTop = Self.radius(
            distanceMeters: distance,
            angleDegrees: EarthflightTuning.headUpDisplayHorizonBarThicknessDegrees / 2
        )
        let gap = Self.radius(
            distanceMeters: distance,
            angleDegrees: EarthflightTuning.headUpDisplayAltimeterGapDegrees
        )
        altimeterText.position = [-mesh.bounds.max.x, armTop + gap - mesh.bounds.min.y, 0]
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

    /// A flat ring in the XY plane, or a disc when the style asks for one. The
    /// stroke is measured radially in degrees, like everything else here.
    private static func circleMesh(distanceMeters: Float) -> MeshResource {
        let outerAngleDegrees = EarthflightTuning.headUpDisplayCircleDiameterDegrees / 2
        let outerRadius = radius(distanceMeters: distanceMeters, angleDegrees: outerAngleDegrees)
        let innerRadius: Float = switch EarthflightTuning.headUpDisplayCircleStyle {
        case .filledDisc:
            0
        case .outlineRing:
            radius(
                distanceMeters: distanceMeters,
                angleDegrees: max(
                    0,
                    outerAngleDegrees - EarthflightTuning.headUpDisplayCircleStrokeDegrees
                )
            )
        }

        // 3.75 degree facets, whose largest departure from a true circle is
        // under a thousandth of the stroke width.
        let segmentCount = 96
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        if innerRadius <= 0 {
            positions.append(.zero)
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

        var descriptor = MeshDescriptor(name: "EarthflightHeadUpDisplayCircle")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        return try! .generate(from: [descriptor])
    }

    /// Two arms either side of the gap, each an arc of the horizontal circle
    /// through the craft. Every point on an arc therefore lies exactly on the
    /// horizon however long the arm is, where a flat bar would only touch it at
    /// the centre and drift above it towards the ends.
    private static func horizonBarMesh(distanceMeters: Float) -> MeshResource {
        let halfThickness = radius(
            distanceMeters: distanceMeters,
            angleDegrees: EarthflightTuning.headUpDisplayHorizonBarThicknessDegrees / 2
        )
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
                let alongHorizon = SIMD3<Float>(
                    distanceMeters * sin(angle),
                    0,
                    -distanceMeters * cos(angle)
                )
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

    private static func radius(distanceMeters: Float, angleDegrees: Double) -> Float {
        distanceMeters * Float(tan(angleDegrees * .pi / 180))
    }

    private static func rimPoint(
        radius: Float,
        segment: Int,
        of segmentCount: Int
    ) -> SIMD3<Float> {
        let angle = 2 * Float.pi * Float(segment) / Float(segmentCount)
        return [radius * cos(angle), radius * sin(angle), 0]
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
        // between the craft and a kilometre ahead.
        material.readsDepth = false
        material.writesDepth = false
        // Neither mark is a closed surface, so winding is not worth reasoning
        // about.
        material.faceCulling = .none
        return material
    }
}
