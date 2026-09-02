import Foundation
import GameController

final class SwitchController {
    private let flightState: FlightState
    private var connectionObserver: NSObjectProtocol?
    private var hasInstalledHandlers = false
    private var isLeftShoulderPressed = false
    private var isRightShoulderPressed = false
    private var isLeftTriggerPressed = false
    private var isRightTriggerPressed = false
    var onJumpToRequested: (@MainActor () -> Void)?

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
            let filteredX = Self.deadZone(xValue)
            let filteredY = Self.deadZone(yValue)
            Task { @MainActor in
                self?.flightState.leftStick = SIMD2(
                    filteredX,
                    filteredY
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
            Task { @MainActor in
                guard let self else { return }
                self.isLeftTriggerPressed = pressed
                self.flightState.isDescending =
                    self.isLeftTriggerPressed || self.isRightTriggerPressed
            }
        }
        gamepad.rightTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in
                guard let self else { return }
                self.isRightTriggerPressed = pressed
                self.flightState.isDescending =
                    self.isLeftTriggerPressed || self.isRightTriggerPressed
            }
        }
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in
                guard let self else { return }
                self.isLeftShoulderPressed = pressed
                self.flightState.isAscending =
                    self.isLeftShoulderPressed || self.isRightShoulderPressed
            }
        }
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in
                guard let self else { return }
                self.isRightShoulderPressed = pressed
                self.flightState.isAscending =
                    self.isLeftShoulderPressed || self.isRightShoulderPressed
            }
        }
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.flightState.isBoosting = pressed }
        }
        // GameController face-button names are positional. On a Switch Pro,
        // physical Y is the left button (buttonX) and physical A is the right
        // button (buttonB).
        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.flightState.isRollingLeft = pressed }
        }
        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.flightState.isRollingRight = pressed }
        }
        gamepad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else {
                return
            }

            Task { @MainActor in self?.flightState.resetView() }
        }
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else {
                return
            }
            Task { @MainActor in self?.onJumpToRequested?() }
        }

        print("Switch Pro Controller flight controls ready.")
    }

    private static func deadZone(_ value: Float) -> Float {
        abs(value) < EarthflightTuning.controllerDeadZone ? 0 : value
    }
}
