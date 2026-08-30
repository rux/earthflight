import Foundation
import simd
import Testing
@testable import earthflight

struct EarthflightTests {
    @Test("Full stick speed scales with altitude and boost")
    @MainActor
    func altitudeAndBoostSpeed() {
        let lowAltitude = FlightState()
        lowAltitude.leftStick = [0, 1]
        lowAltitude.advance(deltaTime: 0.1)
        let lowAltitudeDistance = simd_length(lowAltitude.position - SIMD3<Float>(0, 1.5, 0))

        let highAltitude = FlightState()
        highAltitude.isAscending = true
        for _ in 0..<100 {
            highAltitude.advance(deltaTime: 0.1)
        }
        highAltitude.isAscending = false
        let highStart = highAltitude.position
        highAltitude.leftStick = [0, 1]
        highAltitude.advance(deltaTime: 0.1)
        let highAltitudeDistance = simd_length(highAltitude.position - highStart)

        let boosted = FlightState()
        boosted.leftStick = [0, 1]
        boosted.isBoosting = true
        boosted.advance(deltaTime: 0.1)
        let boostedDistance = simd_length(boosted.position - SIMD3<Float>(0, 1.5, 0))

        #expect(highAltitudeDistance > lowAltitudeDistance)
        #expect(abs(boostedDistance - lowAltitudeDistance * 4) < 0.0001)
    }

    @Test("Pushing the right stick forward pitches the craft nose down")
    @MainActor
    func invertedPitch() {
        let flightState = FlightState()
        flightState.rightStick = [0, 1]
        flightState.advance(deltaTime: 0.1)

        let forwardAfterPitch = flightState.orientation.act(SIMD3<Float>(0, 0, -1))

        #expect(forwardAfterPitch.y < 0)
    }

    @Test("Horizon levelling preserves forward direction and removes roll")
    @MainActor
    func horizonLevelling() {
        let flightState = FlightState()
        flightState.rightStick = [0.3, -0.2]
        flightState.advance(deltaTime: 0.1)
        flightState.rightStick = .zero
        flightState.isRollingRight = true
        flightState.advance(deltaTime: 0.1)
        flightState.isRollingRight = false

        let forwardBeforeLevelling = flightState.orientation.act([0, 0, -1])
        flightState.levelHorizon()

        let forwardAfterLevelling = flightState.orientation.act([0, 0, -1])
        let rightAfterLevelling = flightState.orientation.act([1, 0, 0])

        #expect(simd_length(forwardAfterLevelling - forwardBeforeLevelling) < 0.0001)
        #expect(abs(rightAfterLevelling.y) < 0.0001)
    }

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

    @Test("Cesium Native converts the WGS84 equator to ECEF")
    func cesiumNativeSmokeTest() {
        #expect(CesiumBridge.runSmokeTest().hasPrefix("Cesium Native smoke test: OK"))
    }

    @Test("Cesium Native round-trips a real WGS84 location through ECEF")
    func cesiumNativeCartographicRoundTrip() {
        #expect(
            CesiumBridge.runCartographicRoundTripSmokeTest() ==
                "Cesium Native cartographic round-trip: OK"
        )
    }

    @Test("Google child URLs preserve their session and receive the API key once")
    func googleTileURLDecoration() {
        let key = "test-key"
        let childURL = CesiumBridge.decoratedGoogleURL(
            forTesting: "https://tile.googleapis.com/v1/3dtiles/datasets/example.glb?session=abc123&foo=bar",
            apiKey: key
        )
        let existingKeyURL = CesiumBridge.decoratedGoogleURL(
            forTesting: "https://tile.googleapis.com/v1/3dtiles/root.json?key=already-present",
            apiKey: key
        )
        let otherHostURL = CesiumBridge.decoratedGoogleURL(
            forTesting: "https://example.com/tile.glb?session=abc123",
            apiKey: key
        )

        #expect(childURL.contains("session=abc123"))
        #expect(childURL.contains("foo=bar"))
        #expect(childURL.components(separatedBy: "key=").count == 2)
        #expect(existingKeyURL.contains("key=already-present"))
        #expect(existingKeyURL.components(separatedBy: "key=").count == 2)
        #expect(otherHostURL == "https://example.com/tile.glb?session=abc123")
    }

    @Test("London ENU origin remains metre-scale and east points along local X")
    func londonLocalFrame() {
        #expect(CesiumBridge.runLondonLocalFrameSmokeTest() == "London local ENU frame: OK")
    }
}
