import Foundation
import GameController

/// The bound Switch Pro Controller. The sticks and held buttons are read once a
/// frame through `currentInput`; the one-shot buttons call their actions when
/// pressed.
///
/// GameController's face-button names are positional and say nothing about the
/// glyphs printed on a Nintendo controller. The mapping here was found on the
/// hardware, not inferred.
final class SwitchController {
    var onJumpToRequested: (@MainActor () -> Void)?
    var onHeadUpDisplayToggleRequested: (@MainActor () -> Void)?
    var onViewResetRequested: (@MainActor () -> Void)?
    /// D-pad up and down: how large the wearer is. See `GiantMode`.
    var onGrowRequested: (@MainActor () -> Void)?
    var onShrinkRequested: (@MainActor () -> Void)?

    private var connectionObserver: NSObjectProtocol?
    private var disconnectionObserver: NSObjectProtocol?
    // Matched by identity against GameController's live list, so the same
    // physical controller binds again through the new object GameController
    // hands out when it reconnects.
    private var boundController: GCController?

    // NotificationCenter declares these observer blocks `@Sendable` and offers
    // no main-actor alternative, so Swift 6 will not let the notification's
    // `GCController` cross into this main-actor type. The blocks carry only the
    // signal, and the binding is reconciled against `GCController.controllers()`
    // on this side, which GCController.h asks callers to do anyway.
    //
    // `MainActor.assumeIsolated` is a checked assertion, not a suppression:
    // `queue: .main` runs the block on the main thread, and a main-thread post
    // is delivered synchronously.
    func start() {
        guard connectionObserver == nil else {
            return
        }
        connectionObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileBinding()
            }
        }
        disconnectionObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileBinding()
            }
        }
        reconcileBinding()
    }

    /// Removes this instance's observers and handlers. Safe to call twice or
    /// without `start`.
    func stop() {
        if let connectionObserver {
            NotificationCenter.default.removeObserver(connectionObserver)
        }
        connectionObserver = nil
        if let disconnectionObserver {
            NotificationCenter.default.removeObserver(disconnectionObserver)
        }
        disconnectionObserver = nil
        unbind()
    }

    /// This frame's input, or nil when no controller is bound.
    func currentInput() -> FlightInput? {
        guard let gamepad = boundController?.extendedGamepad else {
            return nil
        }
        // L or R climbs, ZL or ZR descends; both of a pair adds the boost.
        let climbing = gamepad.leftShoulder.isPressed || gamepad.rightShoulder.isPressed
        let descending = gamepad.leftTrigger.isPressed || gamepad.rightTrigger.isPressed
        return FlightInput(
            leftStick: Self.deadZoned(gamepad.leftThumbstick),
            rightStick: Self.deadZoned(gamepad.rightThumbstick),
            vertical: (climbing ? 1 : 0) - (descending ? 1 : 0),
            // On the Switch Pro, `buttonX` rolls left and `buttonY` rolls right.
            roll: (gamepad.buttonY.isPressed ? 1 : 0) - (gamepad.buttonX.isPressed ? 1 : 0),
            // The bottom face button.
            isBoosting: gamepad.buttonA.isPressed,
            isVerticalBoosting:
                (gamepad.leftShoulder.isPressed && gamepad.rightShoulder.isPressed) ||
                (gamepad.leftTrigger.isPressed && gamepad.rightTrigger.isPressed)
        )
    }

    /// Releases a binding whose controller has gone, then binds the first
    /// extended gamepad if nothing is bound.
    private func reconcileBinding() {
        let connectedControllers = GCController.controllers()
        if let boundController,
           !connectedControllers.contains(where: { $0 === boundController }) {
            unbind()
        }
        for controller in connectedControllers {
            bind(controller)
        }
    }

    // The handlers below run on the main thread: GCDevice.h says `handlerQueue`
    // defaults to main, and this app never sets it. Each acts only on the
    // press, so holding a button does nothing more.
    private func bind(_ controller: GCController) {
        guard boundController == nil, let gamepad = controller.extendedGamepad else {
            return
        }
        boundController = controller
        print("Controller connected: vendor=\(controller.vendorName ?? "unknown"), category=\(controller.productCategory)")

        // `buttonMenu` is the physical +, and `buttonOptions` the - beside it.
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.onJumpToRequested?() }
        }
        gamepad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.onHeadUpDisplayToggleRequested?() }
        }
        gamepad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.onViewResetRequested?() }
        }
        gamepad.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.onGrowRequested?() }
        }
        gamepad.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.onShrinkRequested?() }
        }
    }

    private func unbind() {
        guard let gamepad = boundController?.extendedGamepad else {
            boundController = nil
            return
        }
        gamepad.buttonMenu.pressedChangedHandler = nil
        gamepad.buttonOptions?.pressedChangedHandler = nil
        gamepad.rightThumbstickButton?.pressedChangedHandler = nil
        gamepad.dpad.up.pressedChangedHandler = nil
        gamepad.dpad.down.pressedChangedHandler = nil
        boundController = nil
        print("Controller disconnected.")
    }

    private static func deadZoned(_ stick: GCControllerDirectionPad) -> SIMD2<Float> {
        SIMD2(deadZoned(stick.xAxis.value), deadZoned(stick.yAxis.value))
    }

    /// Zero inside the dead zone, then rising from zero at its edge to one at
    /// full travel.
    private static func deadZoned(_ value: Float) -> Float {
        let deadZone = EarthflightTuning.controllerDeadZone
        guard abs(value) > deadZone else {
            return 0
        }
        return (abs(value) - deadZone) / (1 - deadZone) * (value < 0 ? -1 : 1)
    }
}
