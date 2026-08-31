import SwiftUI
import RealityKit
import GameController

struct ImmersiveView: View {
    @State private var flightState = FlightState()
    @State private var switchController: SwitchController?
    @State private var attribution = ""

    var body: some View {
        RealityView { content in
            let googleRenderer = GoogleTileRenderer()
            content.add(googleRenderer.earthRoot)

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
                },
                onAttributionChanged: { currentAttribution in
                    attribution = currentAttribution
                }
            )

            let state = flightState
            let subscription = content.subscribe(to: SceneEvents.Update.self) { _ in
                CesiumBridge.updateStaticLondonTiles()
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
        }
    }
}
