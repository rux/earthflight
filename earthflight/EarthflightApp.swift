import SwiftUI

@main
struct EarthflightApp: App {
    var body: some Scene {
        ImmersiveSpace(id: "EarthflightImmersiveSpace") {
            ImmersiveView()
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

extension Bundle {
    /// The Google Map Tiles key, which the ignored `Secrets.xcconfig` puts in
    /// Info.plist at build time. Empty when it was never set.
    var googleMapsAPIKey: String {
        object(forInfoDictionaryKey: "GoogleMapsAPIKey") as? String ?? ""
    }
}
