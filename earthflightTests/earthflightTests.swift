import Foundation
import Testing

struct EarthflightTests {
    @Test("The app launches directly into full immersion with an extended gamepad")
    func immersiveLaunchConfiguration() {
        let sceneManifest = Bundle.main.object(
            forInfoDictionaryKey: "UIApplicationSceneManifest"
        ) as? [String: Any]
        let defaultRole = sceneManifest?["UIApplicationPreferredDefaultSceneSessionRole"] as? String
        let gameControllerProfiles = Bundle.main.object(
            forInfoDictionaryKey: "GCSupportedGameControllers"
        ) as? [[String: Any]]

        #expect(defaultRole == "UISceneSessionRoleImmersiveSpaceApplication")
        #expect(gameControllerProfiles?.contains { $0["ProfileName"] as? String == "Extended" } == true)
    }
}
