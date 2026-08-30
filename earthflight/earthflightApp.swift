import SwiftUI

@main
struct earthflightApp: App {
    init() {
        print(CesiumBridge.runSmokeTest())
    }

    var body: some Scene {
        ImmersiveSpace(id: "EarthflightImmersiveSpace") {
            ImmersiveView()
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
