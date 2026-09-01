import Foundation
import GameController

final class SwitchController {
    private let flightState: FlightState
    private var connectionObserver: NSObjectProtocol?
    private var hasInstalledHandlers = false

    init(flightState: FlightState) {
        self.flightState = flightState
    }

    func start() {
        connectionObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else {
                return
            }

            self?.installHandlers(for: controller)
        }

        for controller in GCController.controllers() {
            installHandlers(for: controller)
        }
    }

    private func installHandlers(for controller: GCController) {
        guard !hasInstalledHandlers, let gamepad = controller.extendedGamepad else {
            return
        }
        hasInstalledHandlers = true

        print("Controller connected: vendor=\(controller.vendorName ?? "unknown"), category=\(controller.productCategory)")

        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                self?.flightState.leftStick = SIMD2(
                    Self.deadZone(xValue),
                    Self.deadZone(yValue)
                )
            }
        }

        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                self?.flightState.rightStick = SIMD2(
                    Self.deadZone(xValue),
                    Self.deadZone(yValue)
                )
            }
        }

        gamepad.leftTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.flightState.isDescending = pressed }
        }
        gamepad.rightTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.flightState.isAscending = pressed }
        }
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.flightState.isRollingLeft = pressed }
        }
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.flightState.isRollingRight = pressed }
        }
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.flightState.isBoosting = pressed }
        }
        gamepad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else {
                return
            }

            Task { @MainActor in self?.flightState.resetView() }
        }

        print("Switch Pro Controller flight controls ready.")
    }

    private static func deadZone(_ value: Float) -> Float {
        abs(value) < 0.12 ? 0 : value
    }
}
