import ARKit
import QuartzCore
import simd

@MainActor
final class HeadTracking {
    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private var lastValidWorldFromHead: simd_float4x4?

    func start() async {
        guard WorldTrackingProvider.isSupported else {
            print("World tracking is unavailable on this runtime.")
            return
        }

        do {
            try await session.run([worldTracking])
        } catch {
            print("World tracking failed to start: \(error)")
        }
    }

    func currentWorldFromHead() -> simd_float4x4? {
        // ARKit's originFromAnchorTransform is world/origin-from-device in metres,
        // with the same immersive-world coordinate convention RealityKit uses.
        guard worldTracking.state == .running,
              let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              deviceAnchor.isTracked else {
            return lastValidWorldFromHead
        }

        lastValidWorldFromHead = deviceAnchor.originFromAnchorTransform
        return lastValidWorldFromHead
    }
}
