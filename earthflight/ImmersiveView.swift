import SwiftUI
import RealityKit
import GameController

struct ImmersiveView: View {
    @State private var flightState = FlightState()
    @State private var switchController: SwitchController?

    var body: some View {
        RealityView { content in
            // Keep the Milestone 2 world available for diagnostics, but normal Milestone 4
            // execution deliberately presents only the fixed Google location.
            let showsSyntheticFlightWorld = false
            let worldRoot = makeSyntheticFlightWorld()
            let googleRenderer = GoogleTileRenderer()

            if showsSyntheticFlightWorld {
                content.add(worldRoot)
            } else {
                content.add(googleRenderer.earthRoot)
            }

            let apiKey = Bundle.main.object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String ?? ""
            CesiumBridge.startStaticLondonTiles(
                withAPIKey: apiKey,
                onTileVisible: { tileIdentifier, primitives in
                    Task { @MainActor in
                        await googleRenderer.install(primitives: primitives, for: tileIdentifier)
                    }
                },
                onTileFreed: { tileIdentifier in
                    googleRenderer.remove(tileIdentifier: tileIdentifier)
                }
            )

            let state = flightState
            let subscription = content.subscribe(to: SceneEvents.Update.self) { [weak state, weak worldRoot] event in
                CesiumBridge.updateStaticLondonTiles()

                if showsSyntheticFlightWorld, let state, let worldRoot {
                    state.update(worldRoot: worldRoot, deltaTime: event.deltaTime)
                }
            }
            state.keepAlive(subscription)
        }
        .handlesGameControllerEvents(matching: .gamepad)
        .task {
            let controller = SwitchController(flightState: flightState)
            switchController = controller
            controller.start()
        }
    }

    private func makeSyntheticFlightWorld() -> Entity {
        let worldRoot = Entity()

        let floorMaterial = SimpleMaterial(color: .gray, isMetallic: false)
        for x in stride(from: -20, through: 20, by: 2) {
            let line = ModelEntity(
                mesh: .generateBox(size: [0.03, 0.03, 40]),
                materials: [floorMaterial]
            )
            line.position = [Float(x), -1.5, -20]
            worldRoot.addChild(line)
        }

        for z in stride(from: -40, through: 0, by: 2) {
            let line = ModelEntity(
                mesh: .generateBox(size: [40, 0.03, 0.03]),
                materials: [floorMaterial]
            )
            line.position = [0, -1.5, Float(z)]
            worldRoot.addChild(line)
        }

        addMarker(to: worldRoot, position: [-4, 0, -8], color: .red)
        addMarker(to: worldRoot, position: [0, 1, -16], color: .green)
        addMarker(to: worldRoot, position: [5, -0.5, -28], color: .blue)

        return worldRoot
    }

    private func addMarker(to worldRoot: Entity, position: SIMD3<Float>, color: UIColor) {
        let marker = ModelEntity(
            mesh: .generateBox(size: 0.8),
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        marker.position = position
        worldRoot.addChild(marker)
    }
}
