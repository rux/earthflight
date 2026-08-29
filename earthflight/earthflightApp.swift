import SwiftUI

@main
struct earthflightApp: App {
    var body: some Scene {
        ImmersiveSpace(id: "EarthflightImmersiveSpace") {
            ImmersiveView()
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}
