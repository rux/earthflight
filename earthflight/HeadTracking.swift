import ARKit
import QuartzCore
import simd

/// Where the wearer's head is in the immersive world. The head owns the view
/// and nothing else: this never steers the craft.
@MainActor
final class HeadTracking {
    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private var lastValidWorldFromHead: simd_float4x4?
    private var isStopped = false

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

    /// Ends this session's head tracking for good; `ARKitSession` cannot be
    /// restarted, so a later session creates a fresh `HeadTracking`. Also drops
    /// the cached pose so a stray call afterward reports nothing rather than
    /// the last head position this session observed.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        session.stop()
        lastValidWorldFromHead = nil
    }

    /// The head's pose now, or the last one tracked while tracking has dropped
    /// out, or nil before there has been one.
    func currentWorldFromHead() -> simd_float4x4? {
        // ARKit's originFromAnchorTransform is world/origin-from-device in metres,
        // with the same immersive-world coordinate convention RealityKit uses.
        if worldTracking.state == .running,
           let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
           deviceAnchor.isTracked {
            lastValidWorldFromHead = deviceAnchor.originFromAnchorTransform
        }
        return lastValidWorldFromHead
    }
}
