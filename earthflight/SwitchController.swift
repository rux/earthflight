import Foundation
import GameController

final class SwitchController {
    private let flightState: FlightState
    private var connectionObserver: NSObjectProtocol?
    private var disconnectionObserver: NSObjectProtocol?
    // The one controller this instance installed handlers on. A disconnect is
    // matched by object identity and releases the binding with it, so the same
    // physical controller can bind again through whatever fresh GCController
    // object GameController hands out when it reconnects.
    private var boundController: GCController?
    // Handler writes are deferred onto the main actor, so a sample taken just
    // before a disconnect can arrive after neutralisation. Each handler carries
    // the binding it was installed for; a write from a superseded binding is
    // dropped, which keeps neutralisation final and stops a stale input sticking
    // on. Counting bindings, rather than capturing the controller, keeps the
    // handlers free of any reference back to the object holding them.
    private var bindingGeneration = 0
    private var isLeftShoulderPressed = false
    private var isRightShoulderPressed = false
    private var isLeftTriggerPressed = false
    private var isRightTriggerPressed = false
    var onJumpToRequested: (@MainActor () -> Void)?
    var onHeadUpDisplayToggleRequested: (@MainActor () -> Void)?

    init(flightState: FlightState) {
        self.flightState = flightState
    }

    func start() {
        guard connectionObserver == nil else {
            return
        }

        connectionObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else {
                return
            }

            self?.bind(controller)
        }

        disconnectionObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController else {
                return
            }

            self?.unbind(controller)
        }

        for controller in GCController.controllers() {
            bind(controller)
        }
    }

    /// Releases only this instance's observers and handlers and leaves the craft
    /// at rest. Calling it when never started, or twice, does nothing further.
    func stop() {
        if let connectionObserver {
            NotificationCenter.default.removeObserver(connectionObserver)
        }
        connectionObserver = nil
        if let disconnectionObserver {
            NotificationCenter.default.removeObserver(disconnectionObserver)
        }
        disconnectionObserver = nil
        if let boundController {
            unbind(boundController)
        }
    }

    private func bind(_ controller: GCController) {
        guard boundController == nil, let gamepad = controller.extendedGamepad else {
            return
        }
        boundController = controller
        bindingGeneration += 1
        let binding = bindingGeneration

        print("Controller connected: vendor=\(controller.vendorName ?? "unknown"), category=\(controller.productCategory)")

        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            let filteredX = Self.deadZone(xValue)
            let filteredY = Self.deadZone(yValue)
            Task { @MainActor in
                self?.flightState(forBinding: binding)?.leftStick = SIMD2(
                    filteredX,
                    filteredY
                )
            }
        }

        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
            Task { @MainActor in
                self?.flightState(forBinding: binding)?.rightStick = SIMD2(
                    Self.deadZone(xValue),
                    Self.deadZone(yValue)
                )
            }
        }

        gamepad.leftTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in
                guard let self, binding == self.bindingGeneration else { return }
                self.isLeftTriggerPressed = pressed
                self.updateVerticalInput()
            }
        }
        gamepad.rightTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in
                guard let self, binding == self.bindingGeneration else { return }
                self.isRightTriggerPressed = pressed
                self.updateVerticalInput()
            }
        }
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in
                guard let self, binding == self.bindingGeneration else { return }
                self.isLeftShoulderPressed = pressed
                self.updateVerticalInput()
            }
        }
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in
                guard let self, binding == self.bindingGeneration else { return }
                self.isRightShoulderPressed = pressed
                self.updateVerticalInput()
            }
        }
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.flightState(forBinding: binding)?.isBoosting = pressed }
        }
        // GameController face-button names are positional. The physically
        // accepted Switch Pro roll pair reports through buttonX and buttonY.
        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.flightState(forBinding: binding)?.isRollingLeft = pressed }
        }
        gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.flightState(forBinding: binding)?.isRollingRight = pressed }
        }
        gamepad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else {
                return
            }

            Task { @MainActor in self?.flightState(forBinding: binding)?.resetView() }
        }
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else {
                return
            }
            Task { @MainActor in
                guard let self, binding == self.bindingGeneration else { return }
                self.onJumpToRequested?()
            }
        }
        // On the Switch Pro Controller `buttonMenu` is the physical `+` and
        // `buttonOptions` is the `-` beside it.
        gamepad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else {
                return
            }
            Task { @MainActor in
                guard let self, binding == self.bindingGeneration else { return }
                self.onHeadUpDisplayToggleRequested?()
            }
        }

        print("Switch Pro Controller flight controls ready.")
    }

    @MainActor
    private func flightState(forBinding generation: Int) -> FlightState? {
        generation == bindingGeneration ? flightState : nil
    }

    /// A disconnect leaves the craft wherever it was, pointing wherever it was,
    /// but with nothing pressed and nothing decaying, so it stops rather than
    /// coasting on the last inputs a vanished controller reported.
    private func unbind(_ controller: GCController) {
        guard controller === boundController else {
            return
        }

        removeHandlers(from: controller)
        boundController = nil
        bindingGeneration += 1
        isLeftShoulderPressed = false
        isRightShoulderPressed = false
        isLeftTriggerPressed = false
        isRightTriggerPressed = false
        flightState.neutraliseInput()

        print("Controller disconnected. Flight controls neutralised.")
    }

    private func removeHandlers(from controller: GCController) {
        guard let gamepad = controller.extendedGamepad else {
            return
        }

        gamepad.leftThumbstick.valueChangedHandler = nil
        gamepad.rightThumbstick.valueChangedHandler = nil
        gamepad.leftTrigger.pressedChangedHandler = nil
        gamepad.rightTrigger.pressedChangedHandler = nil
        gamepad.leftShoulder.pressedChangedHandler = nil
        gamepad.rightShoulder.pressedChangedHandler = nil
        gamepad.buttonA.pressedChangedHandler = nil
        gamepad.buttonX.pressedChangedHandler = nil
        gamepad.buttonY.pressedChangedHandler = nil
        gamepad.rightThumbstickButton?.pressedChangedHandler = nil
        gamepad.buttonMenu.pressedChangedHandler = nil
        gamepad.buttonOptions?.pressedChangedHandler = nil
    }

    @MainActor
    private func updateVerticalInput() {
        flightState.isAscending = isLeftShoulderPressed || isRightShoulderPressed
        flightState.isDescending = isLeftTriggerPressed || isRightTriggerPressed
        flightState.isVerticalBoosting =
            (isLeftShoulderPressed && isRightShoulderPressed) ||
            (isLeftTriggerPressed && isRightTriggerPressed)
    }

    private static func deadZone(_ value: Float) -> Float {
        abs(value) < EarthflightTuning.controllerDeadZone ? 0 : value
    }
}
