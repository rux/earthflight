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

    @Test("Earth-root transform keeps the rendered craft at its launch pose")
    @MainActor
    func craftDeltaTransformCoherence() {
        let flightState = FlightState()
        let worldFromCraftAtLaunch = flightState.renderLocalFromCraft
        flightState.rightStick = [0.4, -0.3]
        flightState.leftStick = [0.7, 1]

        for _ in 0..<60 {
            flightState.advance(deltaTime: 1.0 / 60.0)
        }

        let worldFromRenderLocal = FlightState.worldFromRenderLocal(
            worldFromCraftAtLaunch: worldFromCraftAtLaunch,
            renderLocalFromCraft: flightState.renderLocalFromCraft
        )
        let representedCraft = worldFromRenderLocal * flightState.renderLocalFromCraft
        let restoredRenderLocalFromCraft =
            worldFromRenderLocal.inverse * worldFromCraftAtLaunch

        #expect(matrixDistance(representedCraft, worldFromCraftAtLaunch) < 1e-8)
        #expect(matrixDistance(restoredRenderLocalFromCraft, flightState.renderLocalFromCraft) < 1e-8)
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

    @Test("Local horizontal origin and RealityKit axes remain metre-scale")
    func localHorizontalFrame() {
        #expect(
            CesiumBridge.runLocalHorizontalFrameSmokeTest() ==
                "RealityKit local horizontal frame: OK"
        )
    }

    @Test("Floating-origin changes preserve represented craft and anchored geometry")
    @MainActor
    func floatingOriginInvariance() {
        let craftEcefPosition = FlightState.ecefPosition(
            longitudeDegrees: 0.35,
            latitudeDegrees: 51.7,
            ellipsoidHeightMeters: 1_250
        )
        let objectEcefPosition = FlightState.ecefPosition(
            longitudeDegrees: 0.351,
            latitudeDegrees: 51.701,
            ellipsoidHeightMeters: 320
        )
        let renderFrameA = EarthflightLocalFrame(
            originEcef: FlightState.ecefPosition(
                longitudeDegrees: -0.1278,
                latitudeDegrees: 51.5074,
                ellipsoidHeightMeters: 120
            )
        )
        let renderFrameB = EarthflightLocalFrame(originEcef: craftEcefPosition)
        let ecefFromCraft = EarthflightLocalFrame(originEcef: craftEcefPosition).ecefFromLocal
        let renderLocalFromCraftA = renderFrameA.localFromEcef * ecefFromCraft
        let renderLocalFromCraftB = renderFrameB.localFromEcef * ecefFromCraft
        var worldFromCraftAtLaunch = matrix_identity_double4x4
        worldFromCraftAtLaunch.columns.3 = SIMD4<Double>(2.5, 1.5, -4, 1)

        let worldFromRenderLocalA = FlightState.worldFromRenderLocal(
            worldFromCraftAtLaunch: worldFromCraftAtLaunch,
            renderLocalFromCraft: renderLocalFromCraftA
        )
        let worldFromRenderLocalB = FlightState.worldFromRenderLocal(
            worldFromCraftAtLaunch: worldFromCraftAtLaunch,
            renderLocalFromCraft: renderLocalFromCraftB
        )
        let representedCraftA = worldFromRenderLocalA * renderLocalFromCraftA
        let representedCraftB = worldFromRenderLocalB * renderLocalFromCraftB

        #expect(matrixDistance(representedCraftA, worldFromCraftAtLaunch) < 1e-8)
        #expect(matrixDistance(representedCraftB, worldFromCraftAtLaunch) < 1e-8)

        let objectInRenderA = renderFrameA.localFromEcef * SIMD4<Double>(objectEcefPosition, 1)
        let objectInRenderB = renderFrameB.localFromEcef * SIMD4<Double>(objectEcefPosition, 1)
        let representedObjectA = FlightState.realityKitMatrix(worldFromRenderLocalA) *
            SIMD4<Float>(Float(objectInRenderA.x), Float(objectInRenderA.y), Float(objectInRenderA.z), 1)
        let representedObjectB = FlightState.realityKitMatrix(worldFromRenderLocalB) *
            SIMD4<Float>(Float(objectInRenderB.x), Float(objectInRenderB.y), Float(objectInRenderB.z), 1)

        // At the 50 km rebase scale, Float ULP and two matrix products remain well
        // below two centimetres. A larger tolerance would conceal visible bad maths.
        #expect(simd_length(representedObjectA - representedObjectB) < 0.02)
    }

    @Test("Planetary movement preserves local-frame and ellipsoid-height invariants")
    @MainActor
    func planetaryMovementAndLocalFrameStability() {
        let representativePositions = [
            (-0.1278, 51.5074, 121.5),
            (12.0, 20.0, 5_000.0),
            (179.999, 0.0, 300.0),
            (40.0, 80.0, 800.0)
        ]

        for (longitude, latitude, height) in representativePositions {
            let ecef = FlightState.ecefPosition(
                longitudeDegrees: longitude,
                latitudeDegrees: latitude,
                ellipsoidHeightMeters: height
            )
            let frame = EarthflightLocalFrame(originEcef: ecef)
            let localPoint = SIMD4<Double>(1_234.5, -67.0, 8_901.25, 1)
            let roundTripped = frame.localFromEcef * (frame.ecefFromLocal * localPoint)
            let x = SIMD3<Double>(frame.ecefFromLocal.columns.0.x,
                                  frame.ecefFromLocal.columns.0.y,
                                  frame.ecefFromLocal.columns.0.z)
            let y = SIMD3<Double>(frame.ecefFromLocal.columns.1.x,
                                  frame.ecefFromLocal.columns.1.y,
                                  frame.ecefFromLocal.columns.1.z)
            let z = SIMD3<Double>(frame.ecefFromLocal.columns.2.x,
                                  frame.ecefFromLocal.columns.2.y,
                                  frame.ecefFromLocal.columns.2.z)

            #expect(simd_length(roundTripped - localPoint) < 1e-6)
            #expect(x.x.isFinite && x.y.isFinite && x.z.isFinite)
            #expect(y.x.isFinite && y.y.isFinite && y.z.isFinite)
            #expect(z.x.isFinite && z.y.isFinite && z.z.isFinite)
            #expect(abs(simd_length(x) - 1) < 1e-12)
            #expect(abs(simd_length(y) - 1) < 1e-12)
            #expect(abs(simd_length(z) - 1) < 1e-12)
            #expect(abs(simd_dot(x, y)) < 1e-12)
            #expect(abs(simd_dot(y, z)) < 1e-12)
            #expect(abs(simd_dot(z, x)) < 1e-12)
        }

        let levelFlight = FlightState()
        let levelStartHeight = levelFlight.ellipsoidHeightMeters
        levelFlight.leftStick = [0.7, 1]
        for _ in 0..<5_000 {
            levelFlight.advance(deltaTime: 0.1)
        }
        #expect(abs(levelFlight.ellipsoidHeightMeters - levelStartHeight) < 0.01)

        let highLatitudeFlight = FlightState(
            longitudeDegrees: 40,
            latitudeDegrees: 80,
            ellipsoidHeightMeters: 800
        )
        highLatitudeFlight.leftStick = [0.6, 1]
        for _ in 0..<1_000 {
            highLatitudeFlight.advance(deltaTime: 0.1)
        }
        #expect(highLatitudeFlight.longitudeDegrees.isFinite)
        #expect(highLatitudeFlight.latitudeDegrees.isFinite)
        #expect(abs(highLatitudeFlight.ellipsoidHeightMeters - 800) < 0.01)

        let antimeridianFlight = FlightState(
            longitudeDegrees: 179.999,
            latitudeDegrees: 0,
            ellipsoidHeightMeters: 300
        )
        antimeridianFlight.leftStick = [1, 0]
        for _ in 0..<100 {
            antimeridianFlight.advance(deltaTime: 0.1)
        }
        #expect(antimeridianFlight.longitudeDegrees >= -180)
        #expect(antimeridianFlight.longitudeDegrees <= 180)
        #expect(antimeridianFlight.longitudeDegrees < -179)
        #expect(antimeridianFlight.latitudeDegrees.isFinite)
        #expect(antimeridianFlight.ellipsoidHeightMeters.isFinite)

        let verticalFlight = FlightState()
        let verticalStartHeight = verticalFlight.ellipsoidHeightMeters
        verticalFlight.isAscending = true
        verticalFlight.advance(deltaTime: 0.1)
        verticalFlight.isAscending = false
        let ascendedHeight = verticalFlight.ellipsoidHeightMeters
        verticalFlight.isDescending = true
        verticalFlight.advance(deltaTime: 0.1)

        #expect(ascendedHeight > verticalStartHeight)
        #expect(verticalFlight.ellipsoidHeightMeters < ascendedHeight)

        let pitchedFlight = FlightState()
        pitchedFlight.rightStick = [0, -0.8]
        pitchedFlight.advance(deltaTime: 0.1)
        pitchedFlight.rightStick = .zero
        let pitchedStartHeight = pitchedFlight.ellipsoidHeightMeters
        pitchedFlight.leftStick = [0, 1]
        pitchedFlight.advance(deltaTime: 0.1)
        #expect(pitchedFlight.ellipsoidHeightMeters > pitchedStartHeight)
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

    private func matrixDistance(_ lhs: simd_double4x4, _ rhs: simd_double4x4) -> Double {
        max(
            simd_length(lhs.columns.0 - rhs.columns.0),
            simd_length(lhs.columns.1 - rhs.columns.1),
            simd_length(lhs.columns.2 - rhs.columns.2),
            simd_length(lhs.columns.3 - rhs.columns.3)
        )
    }
}
