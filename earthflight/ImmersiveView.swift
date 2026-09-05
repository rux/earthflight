import SwiftUI
import RealityKit
import GameController
import simd
import UIKit

struct ImmersiveView: View {
    @State private var flightState = FlightState()
    @State private var switchController: SwitchController?
    @State private var headTracking = HeadTracking()
    @State private var jumpTo = JumpTo()
    @State private var attribution = ""

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
            if let jumpOverlayEntity = attachments.entity(for: "JumpToOverlay") {
                // This attachment is a real immersive entity rather than a window overlay,
                // so it remains visible over the full immersive RealityView.
                jumpOverlayEntity.position = [0, 1.5, -1.25]
                jumpOverlayEntity.components.set(BillboardComponent())
                content.add(jumpOverlayEntity)
            }

            let apiKey = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String ?? ""
            CesiumBridge.startTiles(
                withAPIKey: apiKey,
                maximumScreenSpaceError: EarthflightTuning.maximumScreenSpaceError,
                maximumSimultaneousTileLoads: EarthflightTuning.maximumSimultaneousTileLoads,
                maximumCachedBytes: EarthflightTuning.maximumCachedBytes,
                lodTransitionsEnabled: EarthflightTuning.lodTransitionsEnabled,
                lodTransitionLengthSeconds: EarthflightTuning.lodTransitionLengthSeconds,
                forbidTileHoles: EarthflightTuning.forbidTileHoles,
                drawCoarseAncestorShell: EarthflightTuning.drawCoarseAncestorShell,
                tileRetirementOverlapUpdates: EarthflightTuning.tileRetirementOverlapUpdates,
                logTileRetirementDiagnostics: EarthflightTuning.logTileRetirementDiagnostics,
                onTileVisible: { tileIdentifier, primitives in
                    googleRenderer.show(primitives: primitives, for: tileIdentifier)
                },
                onRenderSetComplete: {
                    googleRenderer.retireTilesNotSelectedThisUpdate()
                },
                onTileFreed: { tileIdentifier in
                    googleRenderer.remove(tileIdentifier: tileIdentifier)
                },
                onAttributionChanged: { currentAttribution in
                    attribution = currentAttribution
                }
            )

            let tracking = headTracking
            let jump = jumpTo
            // Compose the accepted render-local -> immersive-world launch placement
            // with launch craft-local -> render-local so the craft pose remains fixed.
            let initialWorldFromRenderLocal = FlightState.doubleMatrix(
                googleRenderer.earthRoot.transform.matrix
            )
            let worldFromCraftAtLaunch =
                initialWorldFromRenderLocal * state.renderLocalFromCraft
            let subscription = content.subscribe(to: SceneEvents.Update.self) { event in
                if let destination = jump.takePendingDestination() {
                    state.jump(
                        longitudeDegrees: destination.longitudeDegrees,
                        latitudeDegrees: destination.latitudeDegrees,
                        groundEllipsoidHeightMeters: destination.groundEllipsoidHeightMeters,
                        heightAboveGroundMeters: EarthflightTuning.jumpHeightAboveGroundMeters
                    )
                    googleRenderer.setRenderFrame(
                        renderLocalFromEcef: state.renderLocalFromEcef
                    )
                } else if !jump.isActive {
                    state.advance(deltaTime: event.deltaTime)
                    if state.rebaseIfNeeded() {
                        googleRenderer.setRenderFrame(
                            renderLocalFromEcef: state.renderLocalFromEcef
                        )
                    }
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

                googleRenderer.beginUpdate()
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
            }
            state.keepAlive(subscription)
        } attachments: {
            Attachment(id: "JumpToOverlay") {
                VStack(spacing: 8) {
                    Text(jumpTo.displayPrompt)
                    if !jumpTo.transcript.isEmpty {
                        Text(jumpTo.transcript)
                    }
                }
                .font(.title3)
                .padding(18)
                .background(.black.opacity(0.7), in: .rect(cornerRadius: 12))
                .opacity(jumpTo.isActive ? 1 : 0)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            GoogleAttributionView(attribution: attribution)
                .padding(.trailing, CGFloat(EarthflightTuning.attributionTrailingInsetPoints))
        }
        .handlesGameControllerEvents(matching: .gamepad)
        .task {
            let controller = SwitchController(flightState: flightState)
            controller.onJumpToRequested = { jumpTo.start() }
            switchController = controller
            controller.start()
            await headTracking.start()
        }
    }

    private static func makeSkyDome() async -> ModelEntity {
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.opaque = true
        rendererFormat.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 32, height: 512),
            format: rendererFormat
        )
        let image = renderer.image { context in
            if EarthflightTuning.useDiagnosticSkyColour {
                UIColor.magenta.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 512))
                return
            }
            let zenith = UIColor(red: 0.06, green: 0.32, blue: 0.68, alpha: 1).cgColor
            let softSky = UIColor(red: 0.32, green: 0.64, blue: 0.88, alpha: 1).cgColor
            let warmHorizon = UIColor(red: 0.74, green: 0.84, blue: 0.91, alpha: 1).cgColor
            let sandyGround = UIColor(red: 0.62, green: 0.56, blue: 0.46, alpha: 1).cgColor
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [zenith, softSky, warmHorizon, sandyGround] as CFArray,
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
