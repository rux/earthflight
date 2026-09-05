import Foundation
import Metal
import RealityKit
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
        #expect(
            abs(
                boostedDistance -
                    lowAltitudeDistance * Float(EarthflightTuning.boostMultiplier)
            ) < 0.0001
        )
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

    @Test("Tile textures use the first-frame-safe CGImage upload without changing RGBA rows")
    @MainActor
    func tileTextureUploadContract() async throws {
        // Distinct corners catch channel swaps and vertical or horizontal flips.
        let rgba8 = Data([
            255, 0, 0, 255,      0, 255, 0, 255,
            0, 0, 255, 255,      255, 255, 255, 255
        ])
        let resource = try await GoogleTileRenderer.makeTexture(
            rgba8: rgba8,
            width: 2,
            height: 2
        )

        #expect(resource.width == 2)
        #expect(resource.height == 2)

        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        descriptor.usage = .shaderWrite
        let copiedTexture = try #require(device.makeTexture(descriptor: descriptor))
        try await resource.copy(to: copiedTexture)

        var copiedRGBA8 = [UInt8](repeating: 0, count: rgba8.count)
        copiedRGBA8.withUnsafeMutableBytes { bytes in
            copiedTexture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 8,
                from: MTLRegionMake2D(0, 0, 2, 2),
                mipmapLevel: 0
            )
        }
        #expect(copiedRGBA8 == Array(rgba8))
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

    @Test("Jump To starts with no visible status content")
    @MainActor
    func jumpToStartsIdle() {
        let jumpTo = JumpTo()

        #expect(!jumpTo.isActive)
        #expect(jumpTo.displayPrompt.isEmpty)
        #expect(jumpTo.transcript.isEmpty)
    }

    @Test("Bundled EGM96 grid converts mean sea level ground heights")
    func egm96DatumConversion() {
        let egm96 = CesiumBridge.egm96HeightAboveWGS84Ellipsoid(
            atLongitudeDegrees: 0,
            latitudeDegrees: 0
        )
        #expect(abs(egm96 - 17.16) < 0.1)

        let meanSeaLevelGroundElevationMeters = 123.45
        let groundEllipsoidHeightMeters = meanSeaLevelGroundElevationMeters + egm96
        let destinationEllipsoidHeightMeters =
            groundEllipsoidHeightMeters + EarthflightTuning.jumpHeightAboveGroundMeters
        #expect(abs(groundEllipsoidHeightMeters - (meanSeaLevelGroundElevationMeters + egm96)) < 1e-12)
        #expect(
            abs(
                destinationEllipsoidHeightMeters -
                    (groundEllipsoidHeightMeters + EarthflightTuning.jumpHeightAboveGroundMeters)
            ) < 1e-12
        )
    }

    @Test("Atomic jump preserves controls and resets orientation and render origin")
    @MainActor
    func atomicJumpStateInvariants() {
        let flightState = FlightState()
        flightState.rightStick = [0.45, -0.3]
        flightState.leftStick = [0.6, 0.8]
        flightState.isAscending = true
        flightState.isRollingRight = true
        flightState.isBoosting = true
        flightState.advance(deltaTime: 0.2)
        let preservedLeftStick = flightState.leftStick
        let preservedRightStick = flightState.rightStick

        let groundEllipsoidHeightMeters = 2_345.0
        flightState.jump(
            longitudeDegrees: 139.6917,
            latitudeDegrees: 35.6895,
            groundEllipsoidHeightMeters: groundEllipsoidHeightMeters,
            heightAboveGroundMeters: EarthflightTuning.jumpHeightAboveGroundMeters
        )

        #expect(abs(flightState.longitudeDegrees - 139.6917) < 1e-8)
        #expect(abs(flightState.latitudeDegrees - 35.6895) < 1e-8)
        let expectedDestinationHeight =
            groundEllipsoidHeightMeters + EarthflightTuning.jumpHeightAboveGroundMeters
        #expect(abs(flightState.ellipsoidHeightMeters - expectedDestinationHeight) < 1e-5)
        let cartographic = CesiumBridge.cartographicDegrees(fromEcefPosition: flightState.craftEcefPosition)
        #expect(abs(cartographic.x - 139.6917) < 1e-8)
        #expect(abs(cartographic.y - 35.6895) < 1e-8)
        #expect(abs(cartographic.z - expectedDestinationHeight) < 1e-5)
        #expect(flightState.originDistanceMeters < 0.001)
        #expect(
            abs(
                flightState.speedReferenceHeightMeters -
                    EarthflightTuning.jumpHeightAboveGroundMeters
            ) < 1e-5
        )
        let forward = flightState.orientation.act(SIMD3<Float>(0, 0, -1))
        let right = flightState.orientation.act(SIMD3<Float>(1, 0, 0))
        let up = flightState.orientation.act(SIMD3<Float>(0, 1, 0))
        #expect(simd_length(forward - SIMD3<Float>(0, 0, -1)) < 0.0001)
        #expect(simd_length(right - SIMD3<Float>(1, 0, 0)) < 0.0001)
        #expect(simd_length(up - SIMD3<Float>(0, 1, 0)) < 0.0001)
        #expect(flightState.leftStick == preservedLeftStick)
        #expect(flightState.rightStick == preservedRightStick)
        #expect(flightState.isAscending && flightState.isRollingRight && flightState.isBoosting)
        #expect(simd_length(flightState.renderLocalPosition) < 0.001)

        let worldFromCraftAtLaunch = matrix_identity_double4x4
        let worldFromRenderLocal = FlightState.worldFromRenderLocal(
            worldFromCraftAtLaunch: worldFromCraftAtLaunch,
            renderLocalFromCraft: flightState.renderLocalFromCraft
        )
        #expect(matrixDistance(
            worldFromRenderLocal * flightState.renderLocalFromCraft,
            worldFromCraftAtLaunch
        ) < 1e-8)
    }

    @Test("The sky gradient follows air mass from sea level to a distant horizon")
    func skyAirMassAndHorizon() {
        // Straight up from sea level is one vertical column by definition, and it
        // reaches space rather than the ground. The march agrees with the closed
        // form for a horizontal ray, sqrt(pi R H / 2), to well under a percent.
        let groundZenith = SkyAtmosphere.ray(heightMeters: 0, zenithAngleRadians: 0)
        #expect(abs(groundZenith.relativeAirMass - 1) < 0.01)
        #expect(!groundZenith.reachesGround)
        let groundHorizon = SkyAtmosphere.ray(heightMeters: 0, zenithAngleRadians: .pi / 2)
        let closedFormHorizon = (
            .pi * SkyAtmosphere.earthRadiusMeters * SkyAtmosphere.densityScaleHeightMeters / 2
        ).squareRoot() / SkyAtmosphere.densityScaleHeightMeters
        #expect(abs(groundHorizon.relativeAirMass - closedFormHorizon) < 0.2)

        // Sea-level zenith and horizon still produce the accepted blue and pale band.
        let acceptedZenith = SkyGradient.colour(heightMeters: 0, zenithAngleRadians: 0)
        #expect(simd_length(acceptedZenith - SIMD3<Double>(0.06, 0.32, 0.68)) < 0.01)
        let acceptedHorizon = SkyGradient.colour(heightMeters: 0, zenithAngleRadians: .pi / 2)
        #expect(simd_length(acceptedHorizon - SIMD3<Double>(0.74, 0.84, 0.91)) < 0.1)

        // Past the Karman line there is nothing overhead left to scatter, so the
        // sky above is black rather than the light blue it is at ground level.
        let karman = SkyGradient.colour(heightMeters: 100_000, zenithAngleRadians: 0)
        #expect(karman.z < 0.02)

        // Far enough out to see the whole globe the gradient is still horizon
        // aware: the Earth starts exactly where geometry puts its limb, a bright
        // rim survives at that angle, and the sky a few degrees above it is black.
        let farHeight = 20_000_000.0
        let limb = Double.pi - asin(
            SkyAtmosphere.earthRadiusMeters /
                (SkyAtmosphere.earthRadiusMeters + farHeight)
        )
        #expect(!SkyAtmosphere.ray(heightMeters: farHeight, zenithAngleRadians: limb - 0.0002).reachesGround)
        #expect(SkyAtmosphere.ray(heightMeters: farHeight, zenithAngleRadians: limb + 0.0002).reachesGround)
        #expect(SkyGradient.colour(heightMeters: farHeight, zenithAngleRadians: limb - 0.0002).z > 0.5)
        #expect(SkyGradient.colour(heightMeters: farHeight, zenithAngleRadians: limb - 0.01).z < 0.05)

        // The dome keeps the accepted radius while low, then clears the whole
        // visible Earth once the globe would otherwise be hidden behind it.
        #expect(
            SkyDome.radiusMeters(ellipsoidHeightMeters: 1_000) ==
                Double(EarthflightTuning.skyDomeRadiusMeters)
        )
        let farHorizonDistance = (
            pow(SkyAtmosphere.earthRadiusMeters + farHeight, 2) -
                pow(SkyAtmosphere.earthRadiusMeters, 2)
        ).squareRoot()
        #expect(SkyDome.radiusMeters(ellipsoidHeightMeters: farHeight) > farHorizonDistance)
    }

    @Test("The sky palette is smooth and the texture dithers away its 8-bit steps")
    func skyPaletteSmoothnessAndDither() {
        // The cubic must join the tuned stops without inventing colours between
        // them: no overshoot outside the palette, no reversal, and every stop
        // still hit exactly so the accepted colours land where they were tuned.
        var previous = SIMD3<Double>(repeating: -1)
        var sample = 0.0
        while sample < 60 {
            let colour = SkyGradient.scatteredColour(relativeAirMass: sample)
            #expect(colour.min() >= -1e-9 && colour.max() <= 1 + 1e-9)
            #expect(colour.x >= previous.x - 1e-9)
            #expect(colour.y >= previous.y - 1e-9)
            #expect(colour.z >= previous.z - 1e-9)
            previous = colour
            sample += 0.01
        }
        for stop in EarthflightTuning.skyAirMassColourStops {
            let colour = SkyGradient.scatteredColour(relativeAirMass: stop.airMass)
            #expect(simd_length(colour - stop.colour) < 1e-9)
        }

        // Dithering has to preserve the colour it scatters. Averaging a row of
        // texels must land back on the exact value, within well under a level,
        // or the sky drifts away from the palette instead of merely losing its
        // contour lines.
        let rowCount = 256
        let pixels = SkyGradient.pixels(heightMeters: 0, rowCount: rowCount)
        let width = SkyGradient.textureWidth
        var distinctRowMeans = Set<Double>()
        for row in 0..<rowCount {
            let zenithAngle = (Double(row) + 0.5) / Double(rowCount) * .pi
            let exact = SkyGradient.colour(heightMeters: 0, zenithAngleRadians: zenithAngle) * 255
            var sums = SIMD3<Double>(repeating: 0)
            for column in 0..<width {
                let offset = (row * width + column) * 4
                sums += SIMD3(
                    Double(pixels[offset]),
                    Double(pixels[offset + 1]),
                    Double(pixels[offset + 2])
                )
            }
            let means = sums / Double(width)
            #expect(simd_reduce_max(abs(means - exact)) < 0.5)
            distinctRowMeans.insert(means.z)
        }
        // Plain rounding leaves about 30 distinct blue values across these rows,
        // in runs hundreds of rows long, and those runs are the visible bands.
        #expect(distinctRowMeans.count > rowCount / 2)
    }

    @Test("Stars fade in with the thinning sky and stay fixed to the Earth")
    @MainActor
    func starFieldFadeAndAnchor() {
        // The same air mass that paints the sky is what hides the stars, so they
        // are gone at sea level, coming in through the twenties of kilometres,
        // and complete by the time the sky itself is black.
        #expect(StarField.visibility(ellipsoidHeightMeters: 0) < 0.004)
        #expect(StarField.visibility(ellipsoidHeightMeters: 1_000) < 0.01)
        #expect(StarField.visibility(ellipsoidHeightMeters: 100_000) > 0.99)
        var previousVisibility = 0.0
        for step in 0...400 {
            let visibility = StarField.visibility(ellipsoidHeightMeters: Double(step) * 500)
            #expect(visibility >= previousVisibility - 1e-12)
            previousVisibility = visibility
        }

        // Anchoring is the whole reason the field carries an orientation. Render
        // frames rotate as the craft flies and jump at every rebase, so one star
        // direction has to land on the same direction on the Earth from any
        // frame. Getting the rotation inverted here would pop the sky instead.
        let frames = [
            EarthflightLocalFrame(
                originEcef: FlightState.ecefPosition(
                    longitudeDegrees: -0.1278,
                    latitudeDegrees: 51.5074,
                    ellipsoidHeightMeters: 120
                )
            ),
            EarthflightLocalFrame(
                originEcef: FlightState.ecefPosition(
                    longitudeDegrees: 139.6917,
                    latitudeDegrees: 35.6895,
                    ellipsoidHeightMeters: 400_000
                )
            )
        ]
        let starDirection = simd_normalize(SIMD3<Float>(0.3, 0.6, -0.74))
        let earthDirections = frames.map { frame -> SIMD3<Float> in
            let orientation = StarField.earthAnchoredOrientation(
                renderLocalFromEcef: frame.localFromEcef
            )
            let ecefFromRenderLocal = FlightState.realityKitMatrix(frame.ecefFromLocal)
            let inRenderLocal = orientation.act(starDirection)
            let inEcef = ecefFromRenderLocal * SIMD4<Float>(inRenderLocal, 0)
            return SIMD3(inEcef.x, inEcef.y, inEcef.z)
        }
        #expect(simd_length(earthDirections[0] - starDirection) < 1e-5)
        #expect(simd_length(earthDirections[0] - earthDirections[1]) < 1e-5)
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
