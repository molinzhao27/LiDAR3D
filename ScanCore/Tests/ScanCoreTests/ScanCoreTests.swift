import Foundation
import XCTest
@testable import ScanCore

final class FileFormatTests: XCTestCase {
    private let quad = Mesh(
        positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
        colors: [SIMD3(255, 0, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255), SIMD3(10, 20, 30)],
        indices: [0, 1, 2, 0, 2, 3])

    func testPLYRoundTripKeepsGeometryAndColour() throws {
        let data = PLY.encode(quad, comment: "test")
        let header = String(decoding: data.prefix(300), as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("ply\nformat binary_little_endian 1.0\ncomment test\n"))
        XCTAssertEqual(try PLY.decode(data), quad)
    }

    func testPLYBinarySize() {
        let data = PLY.encode(quad)
        let headerLength = data.range(of: Data("end_header\n".utf8))!.upperBound
        XCTAssertEqual(data.count - headerLength, 4 * 15 + 2 * 13)
    }

    func testPLYPointCloudHasNoFaceElement() throws {
        let cloud = Mesh(positions: [SIMD3(1, 2, 3)], colors: [SIMD3(4, 5, 6)])
        let data = PLY.encode(cloud)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("element face"))
        XCTAssertEqual(try PLY.decode(data), cloud)
    }

    func testPLYReadsAsciiQuadsAndFloatColours() throws {
        let text = """
        ply
        format ascii 1.0
        element vertex 4
        property double x
        property double y
        property double z
        property float red
        property float green
        property float blue
        element face 1
        property list uchar uint vertex_indices
        end_header
        0 0 0 1 0 0
        1 0 0 0 1 0
        1 1 0 0 0 1
        0 1 0 1 1 1
        4 0 1 2 3

        """
        let mesh = try PLY.decode(Data(text.utf8))
        XCTAssertEqual(mesh.vertexCount, 4)
        XCTAssertEqual(mesh.indices, [0, 1, 2, 0, 2, 3])
        XCTAssertEqual(mesh.colors[0], SIMD3(255, 0, 0))
        XCTAssertEqual(mesh.colors[3], SIMD3(255, 255, 255))
    }

    func testPLYAcceptsWindowsLineEndings() throws {
        let text = "ply\r\nformat ascii 1.0\r\nelement vertex 1\r\nproperty float x\r\nproperty float y\r\nproperty float z\r\nend_header\r\n1 2 3\r\n"
        XCTAssertEqual(try PLY.decode(Data(text.utf8)).positions, [SIMD3(1, 2, 3)])
    }

    func testPLYRejectsBadIndex() {
        let bad = Mesh(positions: [SIMD3(0, 0, 0)], indices: [0, 0, 5])
        XCTAssertThrowsError(try PLY.decode(PLY.encode(bad)))
    }

    func testSTLLayoutAndRoundTrip() throws {
        let data = STL.encode(quad, unitScale: 1000)
        XCTAssertEqual(data.count, 84 + 2 * 50)
        XCTAssertFalse(data.prefix(5) == Data("solid".utf8))
        let back = try STL.decode(data, unitScale: 1000)
        XCTAssertEqual(back.triangleCount, 2)
        XCTAssertEqual(back.positions[1].x, 1, accuracy: 1e-6)
        // First stored normal should be +z for a counter-clockwise quad in the xy plane.
        let nz = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 84 + 8, as: UInt32.self) }
        XCTAssertEqual(Float(bitPattern: UInt32(littleEndian: nz)), 1, accuracy: 1e-6)
    }
}

final class GeometryTests: XCTestCase {
    func testUnprojectUsesARKitConvention() {
        let k = Intrinsics(fx: 100, fy: 100, cx: 50, cy: 50)
        let p = k.unproject(u: 150, v: 0, depth: 2)
        XCTAssertEqual(p, SIMD3(2, 1, -2))
    }

    func testTransformAppliesRotationThenTranslation() {
        let t = RigidTransform.rotationZ(.pi / 2)
        let p = t.apply(SIMD3(1, 0, 0))
        XCTAssertEqual(p.x, 0, accuracy: 1e-6)
        XCTAssertEqual(p.y, 1, accuracy: 1e-6)
        XCTAssertEqual(RigidTransform.translation(SIMD3(1, 2, 3)).apply(.zero), SIMD3(1, 2, 3))
    }

    func testFilteringDropsTouchingTriangles() {
        let mesh = Mesh(positions: [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0)],
                        indices: [0, 1, 2, 1, 3, 2])
        let kept = mesh.filteringVertices(keep: [true, true, true, false])
        XCTAssertEqual(kept.vertexCount, 3)
        XCTAssertEqual(kept.indices, [0, 1, 2])
    }

    func testSmallComponentsAreRemoved() {
        var mesh = Mesh(positions: [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0)],
                        indices: [0, 1, 2, 1, 3, 2])
        mesh.append(Mesh(positions: [SIMD3(5, 5, 5), SIMD3(6, 5, 5), SIMD3(5, 6, 5)], indices: [0, 1, 2]))
        XCTAssertEqual(mesh.triangleCount, 3)
        let cleaned = mesh.removingSmallComponents(minTriangles: 2)
        XCTAssertEqual(cleaned.triangleCount, 2)
        XCTAssertEqual(cleaned.vertexCount, 4)
    }

    func testAppendFillsMissingColours() {
        var a = Mesh(positions: [.zero])
        a.append(Mesh(positions: [.zero], colors: [SIMD3(1, 2, 3)]))
        XCTAssertEqual(a.colors, [SIMD3(128, 128, 128), SIMD3(1, 2, 3)])
    }
}

final class DepthTests: XCTestCase {
    private func plane(width: Int, height: Int, depth: Float) -> DepthImage {
        DepthImage(width: width, height: height, depth: Array(repeating: depth, count: width * height))
    }

    func testFlatDepthBecomesGridFacingCamera() {
        let image = plane(width: 4, height: 3, depth: 1)
        let k = Intrinsics(fx: 4, fy: 4, cx: 2, cy: 1.5)
        let mesh = DepthMesher.mesh(from: image, intrinsics: k, color: { _, _ in SIMD3(9, 9, 9) })
        XCTAssertEqual(mesh.vertexCount, 12)
        XCTAssertEqual(mesh.triangleCount, 2 * 3 * 2)
        XCTAssertEqual(mesh.colors.count, 12)
        // The camera sits at the origin looking down -z: every face must point back at it (+z).
        for t in 0..<mesh.triangleCount {
            XCTAssertGreaterThan(mesh.faceNormal(t).z, 0.99)
        }
    }

    func testDiscontinuitiesAreNotBridged() {
        var image = plane(width: 4, height: 2, depth: 1)
        image.depth[2] = 2; image.depth[3] = 2; image.depth[6] = 2; image.depth[7] = 2
        let mesh = DepthMesher.mesh(from: image, intrinsics: Intrinsics(fx: 4, fy: 4, cx: 2, cy: 1))
        // Left column pair and right column pair each form one quad; the middle seam is cut.
        XCTAssertEqual(mesh.triangleCount, 4)
    }

    func testDepthRangeAndHolesAreSkipped() {
        var image = plane(width: 3, height: 3, depth: 1)
        image.depth[4] = 0
        image.depth[0] = 9
        let mesh = DepthMesher.mesh(from: image, intrinsics: Intrinsics(fx: 3, fy: 3, cx: 1.5, cy: 1.5),
                                    options: .init(maxDepth: 5))
        XCTAssertFalse(mesh.positions.contains { $0.z < -5 })
        // Only the two triangles that avoid both the hole and the far corner survive.
        XCTAssertEqual(mesh.triangleCount, 2)
        XCTAssertEqual(mesh.vertexCount, 6)
    }

    func testNoSurfaceGivesEmptyMesh() {
        // A single valid pixel can't form a triangle: the result is empty, not a stray vertex.
        let image = DepthImage(width: 2, height: 2, depth: [1, 0, 0, 0])
        XCTAssertTrue(DepthMesher.mesh(from: image, intrinsics: Intrinsics(fx: 2, fy: 2, cx: 1, cy: 1)).isEmpty)
    }

    func testAveragerRejectsOutliersAfterSettling() {
        var avg = DepthAverager(width: 1, height: 1)
        for _ in 0..<3 { avg.add(DepthImage(width: 1, height: 1, depth: [1.0])) }
        avg.add(DepthImage(width: 1, height: 1, depth: [2.0]))
        avg.add(DepthImage(width: 1, height: 1, depth: [1.01]))
        XCTAssertEqual(avg.frameCount, 5)
        XCTAssertEqual(avg.result().depth[0], (3 + 1.01) / 4, accuracy: 1e-5)
        XCTAssertEqual(avg.result(minSamples: 5).depth[0], 0)
    }

    func testStridedCopy() {
        let raw: [Float] = [1, 2, -1, 3, 4, -1]
        let image = raw.withUnsafeBufferPointer { DepthImage(width: 2, height: 2, rowStride: 3, data: $0.baseAddress!) }
        XCTAssertEqual(image.depth, [1, 2, 3, 4])
    }
}

final class VoxelCloudTests: XCTestCase {
    func testPointsInSameVoxelAreAveraged() {
        var cloud = VoxelCloud(voxelSize: 0.1)
        cloud.add(SIMD3(0.01, 0.01, 0.01), color: SIMD3(0, 0, 0))
        cloud.add(SIMD3(0.03, 0.03, 0.03), color: SIMD3(200, 100, 50))
        cloud.add(SIMD3(0.51, 0, 0), color: SIMD3(1, 1, 1))
        XCTAssertEqual(cloud.voxelCount, 2)
        let points = cloud.pointCloud(minObservations: 2)
        XCTAssertEqual(points.vertexCount, 1)
        XCTAssertEqual(points.positions[0].x, 0.02, accuracy: 1e-6)
        XCTAssertEqual(points.colors[0], SIMD3(100, 50, 25))
    }

    func testCapacityLimit() {
        var cloud = VoxelCloud(voxelSize: 1, maxVoxels: 2)
        for i in 0..<5 { cloud.add(SIMD3(Float(i), 0, 0), color: .zero) }
        XCTAssertEqual(cloud.voxelCount, 2)
        XCTAssertTrue(cloud.isFull)
    }

    func testIntegrateUsesPoseAndConfidence() {
        var cloud = VoxelCloud(voxelSize: 0.01)
        let image = DepthImage(width: 2, height: 1, depth: [1, 1])
        let added = cloud.integrate(depth: image, confidence: [2, 0],
                                    intrinsics: Intrinsics(fx: 1, fy: 1, cx: 0, cy: 0),
                                    cameraToWorld: .translation(SIMD3(0, 0, 5)),
                                    options: .init(step: 1, minConfidence: 1),
                                    color: { _, _ in SIMD3(7, 7, 7) })
        XCTAssertEqual(added, 1)
        let p = cloud.pointCloud().positions[0]
        XCTAssertEqual(p.z, 4, accuracy: 1e-5)
    }

    func testColorizeAndCropTrimsUnseenGeometry() {
        var cloud = VoxelCloud(voxelSize: 0.05)
        cloud.add(SIMD3(0, 0, 0), color: SIMD3(10, 20, 30))
        cloud.add(SIMD3(0.1, 0, 0), color: SIMD3(10, 20, 30))
        cloud.add(SIMD3(0, 0.1, 0), color: SIMD3(10, 20, 30))
        let mesh = Mesh(positions: [.zero, SIMD3(0.1, 0, 0), SIMD3(0, 0.1, 0), SIMD3(3, 3, 3)],
                        indices: [0, 1, 2, 1, 3, 2])
        let result = cloud.colorizeAndCrop(mesh)
        XCTAssertEqual(result.triangleCount, 1)
        XCTAssertEqual(result.colors, Array(repeating: SIMD3(10, 20, 30), count: 3))
    }

    func testCropReachIsMetricNotVoxels() {
        // A mesh lying 2 cm off the observed surface, as ARKit's mesh often does.
        var cloud = VoxelCloud(voxelSize: 0.005)
        for x in 0..<20 {
            for y in 0..<20 { cloud.add(SIMD3(Float(x) * 0.005, Float(y) * 0.005, 0), color: SIMD3(9, 9, 9)) }
        }
        let mesh = Mesh(positions: [SIMD3(0.02, 0.02, 0.02), SIMD3(0.06, 0.02, 0.02), SIMD3(0.02, 0.06, 0.02)],
                        indices: [0, 1, 2])
        XCTAssertEqual(cloud.colorizeAndCrop(mesh, maxDistance: 0.03).triangleCount, 1)
        XCTAssertEqual(cloud.colorizeAndCrop(mesh, maxDistance: 0.01).triangleCount, 0)
    }

    func testNearestVoxelFindsClosestPoint() {
        var cloud = VoxelCloud(voxelSize: 0.01)
        cloud.add(SIMD3(0.05, 0, 0), color: SIMD3(1, 0, 0))
        cloud.add(SIMD3(-0.03, 0, 0), color: SIMD3(0, 2, 0))
        XCTAssertEqual(cloud.color(near: .zero, searchRadius: 6), SIMD3(0, 2, 0))
        XCTAssertNil(cloud.color(near: .zero, searchRadius: 2))
    }

    func testIntegrateSkipsFlyingPixels() {
        // A step from 1 m to 2 m: the two pixels either side of it are dropped.
        let image = DepthImage(width: 4, height: 1, depth: [1, 1, 2, 2])
        func integrate(_ jump: Float?) -> Int {
            var cloud = VoxelCloud(voxelSize: 0.01)
            return cloud.integrate(depth: image, intrinsics: Intrinsics(fx: 1, fy: 1, cx: 0, cy: 0),
                                   cameraToWorld: .identity, options: .init(step: 1, maxNeighborJump: jump),
                                   color: { _, _ in .zero })
        }
        XCTAssertEqual(integrate(nil), 4)
        XCTAssertEqual(integrate(0.05), 2)
    }
}

final class TSDFTests: XCTestCase {
    /// Depth map of a sphere `distance` straight ahead of a camera looking down -z.
    private func sphereDepth(radius: Float, distance: Float, size: Int, intrinsics k: Intrinsics) -> DepthImage {
        var depth = [Float](repeating: 0, count: size * size)
        for v in 0..<size {
            for u in 0..<size {
                let ray = SIMD3<Float>((Float(u) - k.cx) / k.fx, -(Float(v) - k.cy) / k.fy, -1)
                let a = (ray * ray).sum()
                let disc = distance * distance - a * (distance * distance - radius * radius)
                guard disc >= 0 else { continue }
                depth[v * size + u] = (distance - disc.squareRoot()) / a
            }
        }
        return DepthImage(width: size, height: size, depth: depth)
    }

    func testRigidInverseUndoesTransform() {
        var m = RigidTransform.rotationZ(0.7)
        m.c3 = SIMD4(1, 2, 3, 1)
        let p = SIMD3<Float>(0.3, -0.2, 0.5)
        let q = m.inverse.apply(m.apply(p))
        XCTAssertEqual(q.x, p.x, accuracy: 1e-5)
        XCTAssertEqual(q.y, p.y, accuracy: 1e-5)
        XCTAssertEqual(q.z, p.z, accuracy: 1e-5)
    }

    func testFusedPlaneLiesOnSurfaceAndFacesCamera() {
        let k = Intrinsics(fx: 40, fy: 40, cx: 20, cy: 20)
        let image = DepthImage(width: 40, height: 40, depth: [Float](repeating: 0.5, count: 1600))
        var volume = TSDFVolume(voxelSize: 0.01, truncation: 0.04)
        for _ in 0..<3 {
            volume.integrate(depth: image, intrinsics: k, cameraToWorld: .identity,
                             options: .init(step: 1), color: { _, _ in SIMD3(200, 100, 50) })
        }
        let mesh = volume.extractMesh(minWeight: 2)
        XCTAssertGreaterThan(mesh.triangleCount, 500)
        for p in mesh.positions { XCTAssertEqual(p.z, -0.5, accuracy: 0.002) }
        var normal = SIMD3<Float>.zero
        for t in 0..<mesh.triangleCount { normal += mesh.faceNormal(t) }
        XCTAssertGreaterThan(normal.z / Float(mesh.triangleCount), 0.99)
        XCTAssertEqual(mesh.colors.first, SIMD3(200, 100, 50))
    }

    func testUnderObservedVoxelsGiveNoSurface() {
        let k = Intrinsics(fx: 40, fy: 40, cx: 20, cy: 20)
        let image = DepthImage(width: 40, height: 40, depth: [Float](repeating: 0.5, count: 1600))
        var volume = TSDFVolume(voxelSize: 0.01)
        volume.integrate(depth: image, intrinsics: k, cameraToWorld: .identity, color: { _, _ in .zero })
        XCTAssertTrue(volume.extractMesh(minWeight: 2).isEmpty)
        XCTAssertFalse(volume.extractMesh(minWeight: 1).isEmpty)
    }

    func testFusedSphereFromFrontAndBack() {
        let k = Intrinsics(fx: 100, fy: 100, cx: 32, cy: 32)
        let image = sphereDepth(radius: 0.1, distance: 0.5, size: 64, intrinsics: k)
        let front = RigidTransform.translation(SIMD3(0, 0, 0.5))
        // Half a turn about +y, standing behind the sphere and looking along +z.
        let back = RigidTransform(SIMD4(-1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 0, -0.5, 1))
        var volume = TSDFVolume(voxelSize: 0.005)
        for pose in [front, back] {
            for _ in 0..<2 {
                volume.integrate(depth: image, intrinsics: k, cameraToWorld: pose,
                                 options: .init(step: 1), color: { _, _ in SIMD3(1, 2, 3) })
            }
        }
        let mesh = volume.extractMesh(minWeight: 2)
        XCTAssertGreaterThan(mesh.triangleCount, 1000)
        let onSurface = mesh.positions.filter { abs(vectorLength($0) - 0.1) < 0.01 }.count
        XCTAssertGreaterThan(Double(onSurface) / Double(mesh.vertexCount), 0.9)
        var outward = 0
        for t in 0..<mesh.triangleCount {
            let corner = mesh.positions[Int(mesh.indices[t * 3])]
            if (mesh.faceNormal(t) * corner).sum() > 0 { outward += 1 }
        }
        XCTAssertGreaterThan(Double(outward) / Double(mesh.triangleCount), 0.9)
        // Both halves are there.
        XCTAssertTrue(mesh.positions.contains { $0.z > 0.09 })
        XCTAssertTrue(mesh.positions.contains { $0.z < -0.09 })
    }
}

final class HTTPTests: XCTestCase {
    func testParsesCompleteRequestOnly() throws {
        XCTAssertNil(try MiniHTTP.parseRequest(Data("GET / HTTP/1.1\r\nHost: x".utf8)))
        let req = try MiniHTTP.parseRequest(Data("GET /files/a%20b/mesh.ply?x=1 HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        XCTAssertEqual(req, MiniHTTP.Request(method: "GET", path: "/files/a%20b/mesh.ply"))
    }

    func testRoutes() {
        XCTAssertEqual(MiniHTTP.route("/"), .index)
        XCTAssertEqual(MiniHTTP.route("/files/a%20b/mesh.ply"), .file(scan: "a b", name: "mesh.ply"))
        XCTAssertEqual(MiniHTTP.route("/files/../secret"), .notFound)
        XCTAssertEqual(MiniHTTP.route("/files/%2E%2E/x.ply"), .notFound)
        XCTAssertEqual(MiniHTTP.route("/files/a/%2Fetc%2Fpasswd"), .notFound)
        XCTAssertEqual(MiniHTTP.route("/files/a/b/c"), .notFound)
    }

    func testIndexPageEscapesAndLinks() {
        let page = MiniHTTP.indexPage(appName: "Scanner", scans: [.init(name: "<Head> 1", files: [("mesh.ply", 2048)])])
        XCTAssertTrue(page.contains("&lt;Head&gt; 1"))
        XCTAssertTrue(page.contains("href=\"/files/%3CHead%3E%201/mesh.ply\""))
        XCTAssertTrue(page.contains("2.0 KB"))
    }
}
