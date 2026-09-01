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

    @Test("Combined yaw and pitch do not introduce roll")
    @MainActor
    func combinedYawAndPitchStayLevel() {
        let flightState = FlightState()
        flightState.rightStick = [0.8, 0.8]

        for _ in 0..<240 {
            flightState.advance(deltaTime: 1.0 / 60.0)
        }

        let craftRight = flightState.orientation.act(SIMD3<Float>(1, 0, 0))
        #expect(abs(craftRight.y) < 0.0001)
    }

    @Test("Craft delta keeps the rendered Earth transform centred on the craft")
    @MainActor
    func craftDeltaTransformCoherence() {
        let flightState = FlightState()
        flightState.rightStick = [0.4, -0.3]
        flightState.leftStick = [0.7, 1]

        for _ in 0..<60 {
            flightState.advance(deltaTime: 1.0 / 60.0)
        }

        let initialCraftPosition = SIMD4<Float>(0, 1.5, 0, 1)
        let currentCraftPosition = SIMD4<Float>(flightState.position, 1)
        let mappedCurrentPosition =
            flightState.localEarthFromCraftDelta * initialCraftPosition
        let restoredInitialPosition =
            flightState.localEarthFromCraftDelta.inverse * currentCraftPosition

        #expect(
            simd_length(
                SIMD3<Float>(mappedCurrentPosition.x, mappedCurrentPosition.y, mappedCurrentPosition.z) -
                    flightState.position
            ) < 0.001
        )
        #expect(
            simd_length(
                SIMD3<Float>(restoredInitialPosition.x, restoredInitialPosition.y, restoredInitialPosition.z) -
                    SIMD3<Float>(0, 1.5, 0)
            ) < 0.001
        )
    }

    @Test("View reset restores the starting orientation")
    @MainActor
    func viewReset() {
        let flightState = FlightState()
        flightState.rightStick = [0.3, -0.2]
        flightState.advance(deltaTime: 0.1)
        flightState.rightStick = .zero
        flightState.isRollingRight = true
        flightState.advance(deltaTime: 0.1)
        flightState.isRollingRight = false

        flightState.resetView()

        let forward = flightState.orientation.act(SIMD3<Float>(0, 0, -1))
        let right = flightState.orientation.act(SIMD3<Float>(1, 0, 0))
        let up = flightState.orientation.act(SIMD3<Float>(0, 1, 0))

        #expect(simd_length(forward - SIMD3<Float>(0, 0, -1)) < 0.0001)
        #expect(simd_length(right - SIMD3<Float>(1, 0, 0)) < 0.0001)
        #expect(simd_length(up - SIMD3<Float>(0, 1, 0)) < 0.0001)
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

    @Test("glTF texture transforms are applied before RealityKit's V conversion")
    func gltfTextureCoordinateConversion() {
        let converted = CesiumBridge.realityKitTextureCoordinateForTesting(
            withU: 0.2,
            v: 0.4,
            offsetU: 0.3,
            offsetV: 0.4,
            scaleU: 0.5,
            scaleV: 0.25,
            rotation: .pi / 2
        )

        #expect(abs(converted[0].doubleValue - 0.4) < 0.000001)
        #expect(abs(converted[1].doubleValue - 0.7) < 0.000001)
    }
}
