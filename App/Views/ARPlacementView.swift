import ARKit
import ScanCore
import SceneKit
import SwiftUI

/// Places a scan at real-world scale on a detected surface.
/// Tap to place or move, pinch to scale, twist to rotate.
struct ARPlacementView: View {
    let mesh: Mesh
    @Environment(\.dismiss) private var dismiss
    @State private var placed = false

    var body: some View {
        ZStack(alignment: .top) {
            ARSceneContainer(mesh: mesh, placed: $placed).ignoresSafeArea()
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
                Text(placed ? "Pinch to scale, twist to rotate" : "Tap a surface to place the scan")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
            }
            .padding()
        }
    }
}

private struct ARSceneContainer: UIViewRepresentable {
    let mesh: Mesh
    @Binding var placed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(node: SceneBuilder.node(for: mesh, pivot: .bottom, unlit: true), placed: $placed)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = true
        context.coordinator.view = view

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        view.session.run(config)

        let coaching = ARCoachingOverlayView()
        coaching.session = view.session
        coaching.goal = .anyPlane
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: view.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap)))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch)))
        view.addGestureRecognizer(UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.rotate)))
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject {
        let node: SCNNode
        var placed: Binding<Bool>
        weak var view: ARSCNView?
        private var baseScale: Float = 1
        private var baseYaw: Float = 0

        init(node: SCNNode, placed: Binding<Bool>) {
            self.node = node
            self.placed = placed
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            guard let query = view.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any),
                  let hit = view.session.raycast(query).first else { return }
            let t = hit.worldTransform.columns.3
            node.simdWorldPosition = SIMD3(t.x, t.y, t.z)
            if node.parent == nil { view.scene.rootNode.addChildNode(node) }
            placed.wrappedValue = true
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began: baseScale = node.simdScale.x
            case .changed:
                let s = min(max(baseScale * Float(gesture.scale), 0.01), 50)
                node.simdScale = SIMD3(repeating: s)
            default: break
            }
        }

        @objc func rotate(_ gesture: UIRotationGestureRecognizer) {
            switch gesture.state {
            case .began: baseYaw = node.simdEulerAngles.y
            case .changed: node.simdEulerAngles.y = baseYaw - Float(gesture.rotation)
            default: break
            }
        }
    }
}
