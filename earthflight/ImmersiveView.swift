import SwiftUI
import RealityKit
import GameController
import simd

/// The whole app: one immersive scene, built once, then flown one frame at a
/// time. Everything that happens each frame is in the scene-update closure
/// below, in the order it happens.
struct ImmersiveView: View {
    /// The SwiftUI panels that hang in the scene.
    private enum Panel: Hashable {
        case jumpTo
        case rateLimitNotice
        case attribution
    }

    @State private var flightState = FlightState()
    @State private var gamepad = Gamepad()
    @State private var headTracking = HeadTracking()
    @State private var jumpTo = JumpTo()
    @State private var giantMode = GiantMode()
    @State private var headUpDisplay = HeadUpDisplay()
    @State private var sky: SkyDome?
    @State private var attribution = ""
    @State private var isRateLimited = false
    // Held here rather than by anything the update closure captures, which
    // would make a retain cycle that no session end could break.
    @State private var sceneUpdateSubscription: EventSubscription?

    var body: some View {
        RealityView { content, attachments in
            let renderer = GoogleTileRenderer(renderLocalFromEcef: flightState.renderLocalFromEcef)
            let sky = await SkyDome(ellipsoidHeightMeters: flightState.ellipsoidHeightMeters)
            self.sky = sky
            renderer.earthRoot.addChild(sky.entity)
            content.add(renderer.earthRoot)

            // The craft's pose in the immersive world, fixed from launch.
            // `earthRoot` starts at identity, so where the craft sits in the
            // render frame now is where it sits in the world for good.
            let worldFromCraftAtLaunch = flightState.renderLocalFromCraft

            // The craft never moves in the world, so the display's frame is
            // placed on it once; the marks inside follow the head. It hangs off
            // `content`, not off `earthRoot`, which moves.
            headUpDisplay.entity.transform = Transform(matrix: simd_float4x4(worldFromCraftAtLaunch))
            content.add(headUpDisplay.entity)
            addPanels(from: attachments, to: &content)

            CesiumBridge.startTiles(
                apiKey: Bundle.main.googleMapsAPIKey,
                settings: Self.tileSelectionSettings,
                onPrepareTile: renderer.prepare(tileIdentifier:payloads:),
                onTileFreed: renderer.remove(tileIdentifier:)
            )

            // Zero, so the first frame measures.
            var secondsUntilGroundMeasurement = 0.0

            sceneUpdateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                let deltaTime = event.deltaTime

                // Fly. A jump takes the place of a frame of flight, and flight
                // waits while one is being spoken and looked up.
                if let destination = jumpTo.takePendingDestination() {
                    flightState.jump(
                        longitudeDegrees: destination.longitudeDegrees,
                        latitudeDegrees: destination.latitudeDegrees,
                        groundEllipsoidHeightMeters: destination.groundEllipsoidHeightMeters,
                        heightAboveGroundMeters: EarthflightTuning.jumpHeightAboveGroundMeters
                    )
                } else if !jumpTo.isActive {
                    flightState.advance(input: gamepad.currentInput(), deltaTime: deltaTime)
                    flightState.rebaseIfNeeded()
                }
                secondsUntilGroundMeasurement -= deltaTime
                if secondsUntilGroundMeasurement <= 0 {
                    secondsUntilGroundMeasurement = EarthflightTuning.groundMeasurementIntervalSeconds
                    flightState.measureGround(
                        CesiumBridge.groundBelow(ecefPosition: flightState.craftEcefPosition)
                    )
                }
                // Not held by Jump To, so a size change already asked for still
                // arrives while the craft waits.
                giantMode.advance(deltaTime: deltaTime)

                // Draw what that left. Double until the last moment; RealityKit
                // takes Float.
                let worldFromRenderLocal = simd_float4x4(FlightState.worldFromRenderLocal(
                    worldFromCraftAtLaunch: worldFromCraftAtLaunch,
                    renderLocalFromCraft: flightState.renderLocalFromCraft,
                    worldScale: giantMode.worldScale
                ))
                renderer.earthRoot.transform = Transform(matrix: worldFromRenderLocal)
                renderer.renderLocalFromEcef = flightState.renderLocalFromEcef
                sky.update(
                    renderLocalPosition: SIMD3<Float>(flightState.renderLocalPosition),
                    renderLocalFromEcef: flightState.renderLocalFromEcef,
                    renderLocalFromCraftTangent: flightState.renderLocalFromCraftTangent,
                    ellipsoidHeightMeters: flightState.ellipsoidHeightMeters,
                    deltaTime: deltaTime
                )
                let worldFromHead = headTracking.currentWorldFromHead()
                // The speed curve's height is the smoothed one, so the marks do
                // not jump in depth each time the ground is measured.
                headUpDisplay.update(
                    craftOrientation: flightState.orientation,
                    groundDistanceHeightMeters: flightState.speedReferenceHeightMeters,
                    altimeterHeightMeters: flightState.heightAboveMeasuredGroundMeters,
                    headWorldPosition: worldFromHead.map { simd_make_float3($0.columns.3) },
                    worldScale: giantMode.worldScale,
                    isJumpToCardShown: jumpTo.isCardShown,
                    deltaTime: deltaTime
                )
                // Written only on a change, so SwiftUI is not asked to redraw
                // the notice every frame. The bridge logs a 429 only when it
                // finally gives up on a tile, so these lines show the retries.
                let isRateLimitedNow =
                    CesiumBridge.secondsSinceRateLimit < EarthflightTuning.rateLimitNoticeSeconds
                if isRateLimitedNow != isRateLimited {
                    isRateLimited = isRateLimitedNow
                    print(isRateLimitedNow
                        ? "Google rate limit: HTTP 429, tile requests waiting to retry"
                        : "Google rate limit: no 429 for \(EarthflightTuning.rateLimitNoticeSeconds) s")
                }

                // Stream. Cesium's camera is the wearer's actual head, carried
                // back through exactly the transform just rendered. Head pose
                // steers tile selection only; it never reaches the flight state
                // or `earthRoot`.
                guard let worldFromHead else {
                    return
                }
                let ecefFromHead = flightState.ecefFromRenderLocal *
                    simd_double4x4(worldFromRenderLocal.inverse * worldFromHead)
                // The head looks down its own -Z with +Y up. The bridge
                // normalises both, which also removes giant mode's scale.
                if let selection = CesiumBridge.updateTiles(
                    cameraPosition: simd_make_double3(ecefFromHead.columns.3),
                    direction: -simd_make_double3(ecefFromHead.columns.2),
                    up: simd_make_double3(ecefFromHead.columns.1),
                    deltaTime: deltaTime
                ) {
                    renderer.show(Set(selection.map(\.uint64Value)))
                }
                let currentAttribution = CesiumBridge.attribution
                if currentAttribution != attribution {
                    attribution = currentAttribution
                }
            }
        } attachments: {
            Attachment(id: Panel.jumpTo) {
                VStack(spacing: 8) {
                    if let place = jumpTo.arrivedPlace {
                        Text(place.name)
                            .font(.title)
                        if let context = place.context {
                            Text(context)
                        }
                    } else {
                        Text(jumpTo.displayPrompt)
                        if !jumpTo.transcript.isEmpty {
                            Text(jumpTo.transcript)
                        }
                    }
                }
                .font(.title2)
                .padding(24)
                .background(.black.opacity(0.7), in: .rect(cornerRadius: 16))
                .opacity(jumpTo.isCardShown ? 1 : 0)
                .allowsHitTesting(false)
            }
            Attachment(id: Panel.rateLimitNotice) {
                Text("Google is limiting tile requests: slow down")
                    .font(.title3)
                    .padding(18)
                    .background(.black.opacity(0.7), in: .rect(cornerRadius: 12))
                    .opacity(isRateLimited ? 1 : 0)
                    .allowsHitTesting(false)
            }
            Attachment(id: Panel.attribution) {
                GoogleAttributionView(attribution: attribution)
            }
        }
        .handlesGameControllerEvents(matching: .gamepad)
        .task {
            gamepad.start { button in
                switch button {
                case .jumpTo: jumpTo.start()
                case .cycleHeadUpDisplay: headUpDisplay.cycleMode()
                case .resetView: flightState.resetView()
                case .grow: giantMode.grow()
                case .shrink: giantMode.shrink()
                }
            }
            await headTracking.start()
        }
        .onDisappear {
            endSession()
        }
    }

    /// Places the panels in the immersive world. An attachment is an entity in
    /// the scene; a window overlay does not present over a full immersive
    /// `RealityView` on hardware. Positions are metres from the immersive
    /// space's origin, on the floor beneath the wearer at launch.
    private func addPanels(from attachments: RealityViewAttachments, to content: inout RealityViewContent) {
        if let card = attachments.entity(for: Panel.jumpTo) {
            card.position = [0, 1.5, -1.25]
            card.components.set(BillboardComponent())
            content.add(card)
        }
        if let notice = attachments.entity(for: Panel.rateLimitNotice) {
            // Below the Jump To card, about 16 degrees under the nose, so it
            // covers neither the view ahead nor the card.
            notice.position = [0, 1.15, -1.25]
            notice.components.set(BillboardComponent())
            content.add(notice)
        }
        if let credits = attachments.entity(for: Panel.attribution) {
            // An attachment faces +z, towards the wearer. Tipping it +90
            // degrees about x turns its face to -y, so it hangs face down
            // above the wearer with the top of the text pointing back
            // towards them, and reads the right way round when they tip
            // their head back to look up. Overhead because the wearer
            // mostly looks down at the world, and the sky is empty. Not
            // billboarded: it stays put, like a placard on a cockpit roof.
            credits.position = [
                0,
                EarthflightTuning.attributionHeightMeters,
                -EarthflightTuning.attributionForwardMeters
            ]
            credits.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            content.add(credits)
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
        gamepad.stop()
        headTracking.stop()
        jumpTo.cancel()
        sky?.stop()
        CesiumBridge.stopTiles()
    }
}
