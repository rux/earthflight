import Foundation
import GameController

// Verified on the owner's M2 Apple Vision Pro with a Nintendo Switch Pro Controller.
// Physical mapping: + → buttonOptions, - → buttonMenu; X(top) → buttonY,
// A(right) → buttonX, B(bottom) → buttonA, Y(left) → buttonB.
// L/R → leftShoulder/rightShoulder; ZL/ZR → leftTrigger/rightTrigger.
// Stick clicks → leftThumbstickButton/rightThumbstickButton. Pushing either
// stick forward is positive Y. D-pad: Up positive Y, Right positive X.
// Home and Capture are system-reserved and do not reach the app.

@MainActor
final class SwitchControllerDiagnostic {
    private var connectionObserver: NSObjectProtocol?
    private var hasInstalledHandlers = false

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

        if let controller = GCController.current ?? GCController.controllers().first {
            installHandlers(for: controller)
        } else {
            print("Waiting for the system to report the connected Switch Pro Controller.")
        }
    }

    private func installHandlers(for controller: GCController) {
        guard !hasInstalledHandlers, let gamepad = controller.extendedGamepad else {
            return
        }
        hasInstalledHandlers = true

        print("Controller connected: vendor=\(controller.vendorName ?? "unknown"), category=\(controller.productCategory)")
        print("Extended gamepad diagnostic ready. Press each physical control once.")

        installDirectionPadHandler(gamepad.leftThumbstick, property: "leftThumbstick", semanticPosition: "left thumbstick")
        installDirectionPadHandler(gamepad.rightThumbstick, property: "rightThumbstick", semanticPosition: "right thumbstick")
        installDirectionPadHandler(gamepad.dpad, property: "dpad", semanticPosition: "directional pad")

        installButtonHandler(gamepad.leftShoulder, property: "leftShoulder", semanticPosition: "left shoulder")
        installButtonHandler(gamepad.rightShoulder, property: "rightShoulder", semanticPosition: "right shoulder")
        installButtonHandler(gamepad.leftTrigger, property: "leftTrigger", semanticPosition: "left trigger")
        installButtonHandler(gamepad.rightTrigger, property: "rightTrigger", semanticPosition: "right trigger")

        installButtonHandler(gamepad.buttonA, property: "buttonA", semanticPosition: "bottom face button")
        installButtonHandler(gamepad.buttonB, property: "buttonB", semanticPosition: "right face button")
        installButtonHandler(gamepad.buttonX, property: "buttonX", semanticPosition: "left face button")
        installButtonHandler(gamepad.buttonY, property: "buttonY", semanticPosition: "top face button")

        installButtonHandler(gamepad.leftThumbstickButton, property: "leftThumbstickButton", semanticPosition: "left stick click")
        installButtonHandler(gamepad.rightThumbstickButton, property: "rightThumbstickButton", semanticPosition: "right stick click")
        installButtonHandler(gamepad.buttonMenu, property: "buttonMenu", semanticPosition: "primary menu button")
        installButtonHandler(gamepad.buttonOptions, property: "buttonOptions", semanticPosition: "secondary menu button")
        installButtonHandler(gamepad.buttonHome, property: "buttonHome", semanticPosition: "home button")
    }

    private func installDirectionPadHandler(
        _ input: GCControllerDirectionPad,
        property: String,
        semanticPosition: String
    ) {
        input.valueChangedHandler = { _, xValue, yValue in
            print("\(property) (semantic: \(semanticPosition)) pressed=\(xValue != 0 || yValue != 0) x=\(xValue) y=\(yValue)")
        }
    }

    private func installButtonHandler(
        _ input: GCControllerButtonInput?,
        property: String,
        semanticPosition: String
    ) {
        guard let input else {
            print("\(property) (semantic: \(semanticPosition)) unavailable")
            return
        }

        input.pressedChangedHandler = { _, value, pressed in
            print("\(property) (semantic: \(semanticPosition)) pressed=\(pressed) value=\(value)")
        }
    }
}
