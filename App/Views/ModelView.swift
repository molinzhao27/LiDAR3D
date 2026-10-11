import ScanCore
import SceneKit
import simd
import SwiftUI

/// Orbit viewer: drag to rotate, pinch to zoom, two fingers to pan.
struct ModelView: UIViewRepresentable {
    let mesh: Mesh
    var unlit: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.scene = SCNScene()
        install(in: view, context: context)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if context.coordinator.mesh != mesh || context.coordinator.unlit != unlit {
            install(in: view, context: context)
        }
    }

    private func install(in view: SCNView, context: Context) {
        context.coordinator.modelNode?.removeFromParentNode()
        let node = SceneBuilder.node(for: mesh, pivot: .center, unlit: unlit)
        view.scene?.rootNode.addChildNode(node)
        context.coordinator.modelNode = node
        context.coordinator.unlit = unlit

        // Re-frame only when the model itself changed, not on a lighting toggle.
        if context.coordinator.mesh != mesh {
            context.coordinator.mesh = mesh
            let radius = mesh.bounds.map { simd_length(($0.max - $0.min) / 2) } ?? 1
            let camera = SCNCamera()
            camera.zNear = Double(max(radius / 100, 0.001))
            camera.zFar = Double(radius * 20)
            let cameraNode = SCNNode()
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0, max(radius, 0.05) * 2.6)
            view.pointOfView?.removeFromParentNode()
            view.scene?.rootNode.addChildNode(cameraNode)
            view.pointOfView = cameraNode
        }
    }

    final class Coordinator {
        var mesh: Mesh?
        var unlit = true
        var modelNode: SCNNode?
    }
}
