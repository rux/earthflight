import Foundation

/// How large the wearer is, counted in doublings above the accepted baseline.
///
/// The Vision Pro's eyes are a fixed 63 mm apart, so binocular depth only reads
/// on things within a few tens of metres. From a craft over a city that is
/// almost nothing, and the view stays flat unless you fly right up to a
/// building.
///
/// The fix is to shrink the whole rendered world uniformly about the craft
/// origin, which the launch placement puts at head height. Scaling about a
/// point leaves every direction from that point unchanged, so a single eye
/// sitting there sees the very same picture: same horizon, same tiles, same
/// projected tile error, which is why Cesium needs no telling and no tile
/// tuning constant moves. What does change is everything measured *across*
/// that point. Each eye's 31.5 mm offset, and any movement of the head, now
/// span `sizeMultiplier` times as much world. That is the whole of the effect:
/// the wearer has grown, and the flight has not changed at all.
///
/// Size is held as a count of doublings, and the ramp between two sizes runs at
/// a constant rate in that count rather than in the multiplier. Size is
/// geometric -- 512 to 1,024 is the same change as 1 to 2 -- so a constant rate
/// in doublings is a constant *perceived* rate, and it keeps every settled
/// level an exact power of two with the baseline at exactly 1.
///
/// There is no reset: hold D-pad down until it stops.
@MainActor
final class GiantMode {
    /// Where the D-pad has asked to be. Zero is the accepted one-to-one world
    /// and the floor; the ceiling is `EarthflightTuning.maximumGiantDoublings`.
    private var targetDoublings = 0

    /// Where the render currently is, chasing the target.
    private var currentDoublings: Double = 0

    /// How many times larger the wearer is than at baseline.
    var sizeMultiplier: Double { exp2(currentDoublings) }

    /// Uniform scale for the rendered world, and the reciprocal of the size
    /// above: a bigger wearer, a smaller world.
    var worldScale: Double { exp2(-currentDoublings) }

    func grow() {
        targetDoublings = min(
            targetDoublings + 1,
            EarthflightTuning.maximumGiantDoublings
        )
    }

    func shrink() {
        targetDoublings = max(targetDoublings - 1, 0)
    }

    /// Moves the rendered size one frame towards the target, at a constant one
    /// doubling per `EarthflightTuning.giantSizeTransitionSeconds`. Pressing
    /// again mid-ramp only moves the target, so two quick presses take twice as
    /// long and arrive without a pause in the middle.
    func advance(deltaTime: TimeInterval) {
        let target = Double(targetDoublings)
        let duration = EarthflightTuning.giantSizeTransitionSeconds
        guard duration > 0 else {
            // Zero disables the ramp entirely, as the release decays do.
            currentDoublings = target
            return
        }

        // Arriving exactly on the target, rather than adding a last remainder
        // to a float, is what keeps a settled level an exact power of two and
        // the baseline exactly 1. It also means a long frame cannot overshoot.
        let step = deltaTime / duration
        if abs(target - currentDoublings) <= step {
            currentDoublings = target
        } else if target > currentDoublings {
            currentDoublings += step
        } else {
            currentDoublings -= step
        }
    }
}
