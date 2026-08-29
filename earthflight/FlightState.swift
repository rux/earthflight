import Foundation
import RealityKit
import simd

@MainActor
final class FlightState {
    private(set) var position = SIMD3<Float>(0, 1.5, 0)
    private(set) var orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    var leftStick = SIMD2<Float>(repeating: 0)
    var rightStick = SIMD2<Float>(repeating: 0)
    var isAscending = false
    var isDescending = false
    var isRollingLeft = false
    var isRollingRight = false
    var isBoosting = false

    private var updateSubscription: EventSubscription?

    func keepAlive(_ subscription: EventSubscription) {
        updateSubscription = subscription
    }

    func update(worldRoot: Entity, deltaTime: TimeInterval) {
        advance(deltaTime: Float(deltaTime))
        worldRoot.transform = worldTransform
    }

    func levelHorizon() {
        // The craft orientation maps local axes into synthetic-world axes.
        // Preserve craft-forward while rebuilding right/up against world up.
        // This removes only roll.
        let forward = simd_normalize(orientation.act([0, 0, -1]))
        let right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        guard simd_length(right) > 0.001 else {
            return
        }

        let levelRight = simd_normalize(right)
        let levelUp = simd_cross(levelRight, forward)
        orientation = simd_quatf(
            simd_float3x3(columns: (levelRight, levelUp, -forward))
        )
    }

    func advance(deltaTime: Float) {
        let dt = min(deltaTime, 0.1)

        let yaw = simd_quatf(angle: -rightStick.x * 1.2 * dt, axis: [0, 1, 0])
        // The verified Switch Pro Controller reports forward stick motion as
        // positive Y. Negative rotation about local X pitches the craft nose down.
        let pitch = simd_quatf(angle: -rightStick.y * 1.0 * dt, axis: [1, 0, 0])
        let rollInput: Float = (isRollingRight ? 1 : 0) - (isRollingLeft ? 1 : 0)
        let roll = simd_quatf(angle: -rollInput * 0.45 * dt, axis: [0, 0, 1])

        orientation = simd_normalize(yaw * orientation * pitch * roll)

        let speed = (2 + max(position.y, 0) * 0.2) * (isBoosting ? 4 : 1)
        let localMovement = SIMD3<Float>(leftStick.x, 0, -leftStick.y)
        let horizontalMovement = orientation.act(localMovement) * speed * dt
        let verticalMovement = SIMD3<Float>(
            0,
            ((isAscending ? 1 : 0) - (isDescending ? 1 : 0)) * speed * dt,
            0
        )

        position += horizontalMovement + verticalMovement
        position.y = max(position.y, 0)
    }

    private var worldTransform: Transform {
        let worldOrientation = orientation.inverse
        let worldPosition = worldOrientation.act(-position)

        return Transform(rotation: worldOrientation, translation: worldPosition)
    }
}
