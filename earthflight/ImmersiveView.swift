import SwiftUI
import RealityKit
import GameController
import simd

struct ImmersiveView: View {
    @State private var flightState = FlightState()
    @State private var switchController = SwitchController()
    @State private var headTracking = HeadTracking()
    @State private var jumpTo = JumpTo()
    @State private var giantMode = GiantMode()
    @State private var attribution = ""
    @State private var sky: SkyDome?
    @State private var headUpDisplay: HeadUpDisplay?
    // Held here rather than by anything the update closure captures, which
    // would make a retain cycle that no session end could break.
    @State private var sceneUpdateSubscription: EventSubscription?

    var body: some View {
        RealityView { content, attachments in
            let state = flightState
            let controller = switchController
            let tracking = headTracking
            let jump = jumpTo
            let giant = giantMode
            let renderer = GoogleTileRenderer(renderLocalFromEcef: state.renderLocalFromEcef)

            let sky = await SkyDome(ellipsoidHeightMeters: state.ellipsoidHeightMeters)
            self.sky = sky
            sky.update(
                renderLocalPosition: state.position,
                renderLocalFromEcef: state.renderLocalFromEcef,
                renderLocalFromCraftTangent: state.renderLocalFromCraftTangent,
                ellipsoidHeightMeters: state.ellipsoidHeightMeters,
                deltaTime: 0
            )
            renderer.earthRoot.addChild(sky.entity)
            content.add(renderer.earthRoot)

            if let jumpOverlayEntity = attachments.entity(for: "JumpToOverlay") {
                // An attachment is an entity in the immersive scene. A window
                // overlay does not present over a full immersive RealityView on
                // hardware.
                jumpOverlayEntity.position = [0, 1.5, -1.25]
                jumpOverlayEntity.components.set(BillboardComponent())
                content.add(jumpOverlayEntity)
            }

            let apiKey = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String ?? ""
            CesiumBridge.startTiles(
                withAPIKey: apiKey,
                settings: Self.tileSelectionSettings,
                onPrepareTile: { tileIdentifier, primitives in
                    renderer.prepare(tileIdentifier: tileIdentifier, primitives: primitives)
                },
                onTileSelected: { tileIdentifier in
                    renderer.markSelected(tileIdentifier: tileIdentifier)
                },
                onSelectionComplete: {
                    renderer.showSelection()
                },
                onTileFreed: { tileIdentifier in
                    renderer.remove(tileIdentifier: tileIdentifier)
                },
                onAttributionChanged: { currentAttribution in
                    attribution = currentAttribution
                }
            )

            // The craft's pose in the immersive world, fixed from launch: the
            // first render-local -> world placement composed with craft ->
            // render-local.
            let worldFromCraftAtLaunch =
                simd_double4x4(renderer.earthRoot.transform.matrix) * state.renderLocalFromCraft

            // The craft never moves in the world, so the display on it is placed
            // once. It hangs off `content`, not off `earthRoot`, which moves.
            let headUpDisplay = HeadUpDisplay()
            headUpDisplay.entity.transform = Transform(matrix: simd_float4x4(worldFromCraftAtLaunch))
            content.add(headUpDisplay.entity)
            self.headUpDisplay = headUpDisplay

            sceneUpdateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                if let destination = jump.takePendingDestination() {
                    state.jump(
                        longitudeDegrees: destination.longitudeDegrees,
                        latitudeDegrees: destination.latitudeDegrees,
                        groundEllipsoidHeightMeters: destination.groundEllipsoidHeightMeters,
                        heightAboveGroundMeters: EarthflightTuning.jumpHeightAboveGroundMeters
                    )
                    renderer.setRenderFrame(renderLocalFromEcef: state.renderLocalFromEcef)
                } else if !jump.isActive {
                    state.advance(input: controller.currentInput(), deltaTime: event.deltaTime)
                    if state.rebaseIfNeeded() {
                        renderer.setRenderFrame(renderLocalFromEcef: state.renderLocalFromEcef)
                    }
                }
                sky.update(
                    renderLocalPosition: state.position,
                    renderLocalFromEcef: state.renderLocalFromEcef,
                    renderLocalFromCraftTangent: state.renderLocalFromCraftTangent,
                    ellipsoidHeightMeters: state.ellipsoidHeightMeters,
                    deltaTime: event.deltaTime
                )
                headUpDisplay.update(
                    craftOrientation: state.orientation,
                    isJumpToActive: jump.isActive
                )
                // Outside the jump branch, like the sky and the display, so a size
                // change already asked for still arrives while Jump To holds the
                // craft still.
                giant.advance(deltaTime: event.deltaTime)

                // Double until the last moment; RealityKit takes Float.
                let worldFromRenderLocal = simd_float4x4(FlightState.worldFromRenderLocal(
                    worldFromCraftAtLaunch: worldFromCraftAtLaunch,
                    renderLocalFromCraft: state.renderLocalFromCraft,
                    worldScale: giant.worldScale
                ))
                renderer.earthRoot.transform = Transform(matrix: worldFromRenderLocal)

                guard let worldFromHead = tracking.currentWorldFromHead() else {
                    return
                }
                // Cesium's camera is the wearer's actual head, carried back
                // through exactly the transform just rendered. Head pose steers
                // tile selection only; it never reaches the flight state or
                // `earthRoot`.
                let ecefFromHead = state.ecefFromRenderLocal *
                    simd_double4x4(worldFromRenderLocal.inverse * worldFromHead)
                renderer.beginSelection()
                // The head looks down its own -Z with +Y up. The bridge
                // normalises both, which also removes giant mode's scale.
                CesiumBridge.updateTiles(
                    withCameraPosition: simd_make_double3(ecefFromHead.columns.3),
                    direction: -simd_make_double3(ecefFromHead.columns.2),
                    up: simd_make_double3(ecefFromHead.columns.1),
                    deltaTime: event.deltaTime
                )
            }
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
            switchController.onJumpToRequested = { jumpTo.start() }
            switchController.onHeadUpDisplayToggleRequested = { headUpDisplay?.toggle() }
            switchController.onViewResetRequested = { flightState.resetView() }
            switchController.onGrowRequested = { giantMode.grow() }
            switchController.onShrinkRequested = { giantMode.shrink() }
            switchController.start()
            await headTracking.start()
        }
        .onDisappear {
            endSession()
        }
    }

    private static var tileSelectionSettings: CesiumTileSelectionSettings {
        CesiumTileSelectionSettings(
            maximumScreenSpaceErrorHeadsetPixels: EarthflightTuning.maximumScreenSpaceErrorHeadsetPixels,
            headsetPixelsPerDegree: EarthflightTuning.headsetPixelsPerDegree,
            horizontalFieldOfViewDegrees: EarthflightTuning.tileSelectionHorizontalFieldOfViewDegrees,
            verticalFieldOfViewDegrees: EarthflightTuning.tileSelectionVerticalFieldOfViewDegrees,
            forbidHoles: EarthflightTuning.forbidTileHoles,
            loadingDescendantLimit: EarthflightTuning.loadingDescendantLimit,
            maximumSimultaneousTileLoads: EarthflightTuning.maximumSimultaneousTileLoads,
            maximumCachedBytes: EarthflightTuning.maximumCachedBytes
        )
    }

    /// Ends the session explicitly rather than leaving it to whatever order ARC
    /// tears down the scene's entities and closures. visionOS calls this when the
    /// immersive space closes, for example from the Digital Crown, and nothing
    /// may be left that could call into a later session. Every step is safe to
    /// repeat.
    private func endSession() {
        sceneUpdateSubscription = nil
        switchController.stop()
        headTracking.stop()
        jumpTo.cancel()
        sky?.stop()
        CesiumBridge.stopTiles()
    }
}
