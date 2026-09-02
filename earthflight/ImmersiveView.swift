import SwiftUI
import RealityKit
import GameController
import simd
import UIKit

struct ImmersiveView: View {
    @State private var flightState = FlightState()
    @State private var switchController: SwitchController?
    @State private var headTracking = HeadTracking()
    @State private var attribution = ""
#if DEBUG
    @State private var debugTelemetry = DebugTelemetry()
#endif

    var body: some View {
        RealityView { content, attachments in
            let state = flightState
            let googleRenderer = GoogleTileRenderer(
                renderLocalFromEcef: state.renderLocalFromEcef
            )
            let skyDome = await Self.makeSkyDome()
            skyDome.position = state.position
            googleRenderer.earthRoot.addChild(skyDome)
            content.add(googleRenderer.earthRoot)

#if DEBUG
            if let telemetryEntity = attachments.entity(for: "PlanetaryTelemetry") {
                // Immersive-world metres relative to the launch origin: half a metre
                // left, 1.5 metres up, and 1.5 metres in front of the wearer.
                telemetryEntity.position = [-0.5, 1.5, -1.5]
                telemetryEntity.components.set(BillboardComponent())
                content.add(telemetryEntity)
            }
#endif

            let apiKey = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String ?? ""
            CesiumBridge.startTiles(
                withAPIKey: apiKey,
                maximumScreenSpaceError: EarthflightTuning.maximumScreenSpaceError,
                maximumCachedBytes: EarthflightTuning.maximumCachedBytes,
                onTileVisible: { tileIdentifier, primitives in
                    googleRenderer.show(primitives: primitives, for: tileIdentifier)
                },
                onTileHidden: { tileIdentifier in
                    googleRenderer.hide(tileIdentifier: tileIdentifier)
                },
                onTileFreed: { tileIdentifier in
                    googleRenderer.remove(tileIdentifier: tileIdentifier)
                },
                onAttributionChanged: { currentAttribution in
                    attribution = currentAttribution
                }
            )

            let tracking = headTracking
            // render-local -> immersive world at launch is the physically accepted
            // Milestone 5 placement. Compose it with launch craft-local -> render-local
            // so the resulting craft pose remains fixed through movement and rebases.
            let initialWorldFromRenderLocal = FlightState.doubleMatrix(
                googleRenderer.earthRoot.transform.matrix
            )
            let worldFromCraftAtLaunch =
                initialWorldFromRenderLocal * state.renderLocalFromCraft
            var debugElapsed: TimeInterval = 0

            let subscription = content.subscribe(to: SceneEvents.Update.self) { event in
                state.advance(deltaTime: event.deltaTime)
                if state.rebaseIfNeeded() {
                    googleRenderer.setRenderFrame(
                        renderLocalFromEcef: state.renderLocalFromEcef
                    )
                }
                // The dome shares the Earth-root rotation but stays centred on the
                // virtual craft in the current render frame.
                skyDome.position = state.position

                // render-local -> world = fixed world-from-launch-craft followed by
                // inverse(current render-local-from-craft). Double is retained until
                // assigning RealityKit's metre-scale Float Earth-root transform.
                let worldFromRenderLocalDouble = FlightState.worldFromRenderLocal(
                    worldFromCraftAtLaunch: worldFromCraftAtLaunch,
                    renderLocalFromCraft: state.renderLocalFromCraft
                )
                let worldFromRenderLocal = FlightState.realityKitMatrix(
                    worldFromRenderLocalDouble
                )
                googleRenderer.earthRoot.transform = Transform(matrix: worldFromRenderLocal)

                guard let worldFromHead = tracking.currentWorldFromHead() else {
                    return
                }

                // Derive Cesium's virtual camera from the exact rendered relationship.
                // Head translation/orientation affects selection but is never written
                // into FlightState or the Earth-root transform.
                let renderLocalFromHead =
                    worldFromRenderLocal.inverse * worldFromHead
                let ecefFromHead = state.ecefFromRenderLocal *
                    FlightState.doubleMatrix(renderLocalFromHead)
                let ecefCameraPosition = SIMD3<Double>(
                    ecefFromHead.columns.3.x,
                    ecefFromHead.columns.3.y,
                    ecefFromHead.columns.3.z
                )
                let ecefDirection4 = ecefFromHead * SIMD4<Double>(0, 0, -1, 0)
                let ecefUp4 = ecefFromHead * SIMD4<Double>(0, 1, 0, 0)
                let ecefCameraDirection = simd_normalize(
                    SIMD3<Double>(ecefDirection4.x, ecefDirection4.y, ecefDirection4.z)
                )
                var ecefCameraUp = SIMD3<Double>(ecefUp4.x, ecefUp4.y, ecefUp4.z)
                ecefCameraUp -= simd_dot(ecefCameraUp, ecefCameraDirection) *
                    ecefCameraDirection
                ecefCameraUp = simd_normalize(ecefCameraUp)

                CesiumBridge.updateTiles(
                    withEcefCameraPositionX: ecefCameraPosition.x,
                    positionY: ecefCameraPosition.y,
                    positionZ: ecefCameraPosition.z,
                    directionX: ecefCameraDirection.x,
                    directionY: ecefCameraDirection.y,
                    directionZ: ecefCameraDirection.z,
                    upX: ecefCameraUp.x,
                    upY: ecefCameraUp.y,
                    upZ: ecefCameraUp.z,
                    deltaTime: event.deltaTime
                )

#if DEBUG
                debugElapsed += event.deltaTime
                if debugElapsed >= 1 {
                    debugElapsed = 0
                    debugTelemetry = DebugTelemetry(
                        latitudeDegrees: state.latitudeDegrees,
                        longitudeDegrees: state.longitudeDegrees,
                        ellipsoidHeightMeters: state.ellipsoidHeightMeters,
                        originDistanceMeters: state.originDistanceMeters,
                        rebaseCount: state.rebaseCount
                    )
                    print(
                        "Planetary lat=\(state.latitudeDegrees) lon=\(state.longitudeDegrees) " +
                        "ellipsoid=\(state.ellipsoidHeightMeters) " +
                        "speedReference=\(state.speedReferenceHeightMeters) " +
                        "originDistance=\(state.originDistanceMeters) rebases=\(state.rebaseCount) " +
                        "craftLocal=\(state.renderLocalPosition) " +
                        googleRenderer.debugResourceSummary
                    )
                }
#endif
            }
            state.keepAlive(subscription)
        } attachments: {
#if DEBUG
            Attachment(id: "PlanetaryTelemetry") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: String(
                        format: "Lat/Lon: %.5f°, %.5f°",
                        debugTelemetry.latitudeDegrees,
                        debugTelemetry.longitudeDegrees
                    ))
                    Text(verbatim: String(
                        format: "Ellipsoid: %.1f m",
                        debugTelemetry.ellipsoidHeightMeters
                    ))
                    Text(verbatim: String(
                        format: "Origin distance: %.2f km",
                        debugTelemetry.originDistanceMeters / 1_000
                    ))
                    Text(verbatim: "Rebases: \(debugTelemetry.rebaseCount)")
                }
                .font(.caption.monospacedDigit())
                .padding(8)
                .background(.black.opacity(0.55), in: .rect(cornerRadius: 8))
            }
#endif
        }
        .overlay(alignment: .bottomTrailing) {
            GoogleAttributionView(attribution: attribution)
        }
        .handlesGameControllerEvents(matching: .gamepad)
        .task {
            let controller = SwitchController(flightState: flightState)
            switchController = controller
            controller.start()
            await headTracking.start()
        }
    }

#if DEBUG
    private struct DebugTelemetry {
        var latitudeDegrees = FlightState.launchLatitudeDegrees
        var longitudeDegrees = FlightState.launchLongitudeDegrees
        var ellipsoidHeightMeters = FlightState.launchCraftEllipsoidHeightMeters
        var originDistanceMeters = 1.5
        var rebaseCount = 0
    }
#endif

    private static func makeSkyDome() async -> ModelEntity {
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.opaque = true
        rendererFormat.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 32, height: 512),
            format: rendererFormat
        )
        let image = renderer.image { context in
            let zenith = UIColor(red: 0.06, green: 0.32, blue: 0.68, alpha: 1).cgColor
            let softSky = UIColor(red: 0.32, green: 0.64, blue: 0.88, alpha: 1).cgColor
            let warmHorizon = UIColor(red: 0.74, green: 0.84, blue: 0.91, alpha: 1).cgColor
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [zenith, softSky, warmHorizon, warmHorizon] as CFArray,
                locations: [0, 0.28, 0.5, 1]
            )!
            context.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: 0, y: 512),
                options: []
            )
        }
        let texture = try! await TextureResource(
            image: image.cgImage!,
            withName: "EarthflightSkyGradient",
            options: TextureResource.CreateOptions(semantic: .color)
        )
        var material = UnlitMaterial(texture: texture)
        material.faceCulling = .front

        return ModelEntity(
            mesh: .generateSphere(radius: EarthflightTuning.skyDomeRadiusMeters),
            materials: [material]
        )
    }
}
