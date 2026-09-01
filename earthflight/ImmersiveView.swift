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

    var body: some View {
        RealityView { content in
            let googleRenderer = GoogleTileRenderer()
            let state = flightState
            let skyDome = await Self.makeSkyDome()
            skyDome.position = state.position
            googleRenderer.earthRoot.addChild(skyDome)
            content.add(googleRenderer.earthRoot)

            let apiKey = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String ?? ""
            CesiumBridge.startLondonTiles(
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
            // Milestone 4 installed the fixed-London Earth root directly in
            // immersive world space. Preserve that validated placement exactly.
            let baseWorldFromLocalEarth = googleRenderer.earthRoot.transform.matrix
            var debugElapsed: TimeInterval = 0

            let subscription = content.subscribe(to: SceneEvents.Update.self) { event in
                state.advance(deltaTime: event.deltaTime)
                // The dome shares the Earth-root rotation but stays centred on the
                // virtual craft, so it cannot be reached by flying through London.
                skyDome.position = state.position

                // localEarthFromCraftDelta is craft-local -> fixed London local,
                // in metres, right-handed x=east/y=up/z=-north. Multiplication is
                // right-to-left: first undo craft motion, then apply the calibrated
                // Milestone 4 Earth placement in immersive world space.
                let worldFromLocalEarth = baseWorldFromLocalEarth * state.localEarthFromCraftDelta.inverse
                googleRenderer.earthRoot.transform = Transform(matrix: worldFromLocalEarth)

                guard let worldFromHead = tracking.currentWorldFromHead() else {
                    return
                }

                // Derive Cesium's virtual camera from the exact rendered relationship.
                // Head translation/orientation affects selection but is never written
                // into FlightState or the Earth-root transform.
                let localEarthFromHead = worldFromLocalEarth.inverse * worldFromHead
                let localCameraPosition = SIMD3<Double>(
                    Double(localEarthFromHead.columns.3.x),
                    Double(localEarthFromHead.columns.3.y),
                    Double(localEarthFromHead.columns.3.z)
                )
                let localDirection4 = localEarthFromHead * SIMD4<Float>(0, 0, -1, 0)
                let localUp4 = localEarthFromHead * SIMD4<Float>(0, 1, 0, 0)
                let localCameraDirection = simd_normalize(
                    SIMD3<Float>(localDirection4.x, localDirection4.y, localDirection4.z))
                let localCameraUp = simd_normalize(
                    SIMD3<Float>(localUp4.x, localUp4.y, localUp4.z))
                let localCameraRight = simd_normalize(
                    simd_cross(localCameraDirection, localCameraUp))
                let craftUp = state.orientation.act(SIMD3<Float>(0, 1, 0))
                let craftRight = state.orientation.act(SIMD3<Float>(1, 0, 0))

                CesiumBridge.updateLondonTiles(
                    withCameraPositionX: localCameraPosition.x,
                    positionY: localCameraPosition.y,
                    positionZ: localCameraPosition.z,
                    directionX: Double(localCameraDirection.x),
                    directionY: Double(localCameraDirection.y),
                    directionZ: Double(localCameraDirection.z),
                    upX: Double(localCameraUp.x),
                    upY: Double(localCameraUp.y),
                    upZ: Double(localCameraUp.z),
                    deltaTime: event.deltaTime
                )

#if DEBUG
                debugElapsed += event.deltaTime
                if debugElapsed >= 1 {
                    debugElapsed = 0
                    print(
                        "Flight local=\(state.localEarthPosition) cameraLocal=\(localCameraPosition) " +
                        "cameraForward=\(localCameraDirection) craftUp=\(craftUp) " +
                        "craftRightY=\(craftRight.y) cameraRightY=\(localCameraRight.y) " +
                        googleRenderer.debugResourceSummary
                    )
                }
#endif
            }
            state.keepAlive(subscription)
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
            mesh: .generateSphere(radius: 100_000),
            materials: [material]
        )
    }
}
