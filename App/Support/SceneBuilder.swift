import ScanCore
import SceneKit
import UIKit

/// Turns a scan into SceneKit geometry for the 3D and AR viewers.
enum SceneBuilder {
    enum Pivot {
        /// Origin at the centre of the bounding box (orbit viewer).
        case center
        /// Origin at the bottom centre (sits on a surface in AR).
        case bottom
    }

    static func node(for mesh: Mesh, pivot: Pivot, unlit: Bool) -> SCNNode {
        let geometry = makeGeometry(mesh, unlit: unlit)
        let node = SCNNode(geometry: geometry)
        if let bounds = mesh.bounds {
            let center = (bounds.min + bounds.max) / 2
            switch pivot {
            case .center: node.position = SCNVector3(-center.x, -center.y, -center.z)
            case .bottom: node.position = SCNVector3(-center.x, -bounds.min.y, -center.z)
            }
        }
        // Wrap so callers can move/scale the container without fighting the offset.
        let container = SCNNode()
        container.addChildNode(node)
        return container
    }

    static func makeGeometry(_ mesh: Mesh, unlit: Bool) -> SCNGeometry {
        var sources = [SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) })]

        if mesh.hasColors {
            let rgb: [Float] = mesh.colors.flatMap { [Float($0.x) / 255, Float($0.y) / 255, Float($0.z) / 255] }
            let data = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color, vectorCount: mesh.vertexCount,
                                             usesFloatComponents: true, componentsPerVector: 3,
                                             bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                             dataStride: MemoryLayout<Float>.size * 3))
        }

        let element: SCNGeometryElement
        if mesh.isPointCloud {
            let indices = (0..<UInt32(mesh.vertexCount)).map { $0 }
            element = SCNGeometryElement(indices: indices, primitiveType: .point)
            element.pointSize = 3
            element.minimumPointScreenSpaceRadius = 1
            element.maximumPointScreenSpaceRadius = 4
        } else {
            sources.append(SCNGeometrySource(normals: mesh.vertexNormals().map { SCNVector3($0.x, $0.y, $0.z) }))
            element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        }

        let geometry = SCNGeometry(sources: sources, elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = mesh.hasColors ? UIColor.white : UIColor(white: 0.8, alpha: 1)
        // Scanned colour already contains the real-world lighting, so unlit
        // shows it as captured; shaded makes the surface shape easier to read.
        material.lightingModel = unlit || mesh.isPointCloud ? .constant : .blinn
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}
