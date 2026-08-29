import SwiftUI
import RealityKit
import GameController

struct ImmersiveView: View {
    @State private var controllerDiagnostic = SwitchControllerDiagnostic()

    var body: some View {
        RealityView { content in
            let redCube = ModelEntity(
                mesh: .generateBox(size: 0.2),
                materials: [SimpleMaterial(color: .red, isMetallic: false)]
            )
            redCube.position = [-0.5, 0, -1]

            let greenCube = ModelEntity(
                mesh: .generateBox(size: 0.2),
                materials: [SimpleMaterial(color: .green, isMetallic: false)]
            )
            greenCube.position = [0, 0.25, -1.5]

            let blueCube = ModelEntity(
                mesh: .generateBox(size: 0.2),
                materials: [SimpleMaterial(color: .blue, isMetallic: false)]
            )
            blueCube.position = [0.5, -0.15, -2]

            content.add(redCube)
            content.add(greenCube)
            content.add(blueCube)
        }
        .handlesGameControllerEvents(matching: .gamepad)
        .task {
            controllerDiagnostic.start()
        }
    }
}
