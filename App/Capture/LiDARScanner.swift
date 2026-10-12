import ARKit
import Foundation
import RealityKit
import ScanCore

/// Rear LiDAR scanning for rooms, bodies, furniture and other larger objects.
///
/// Several things are built at once while the user walks around the subject:
/// - Every few frames the LiDAR depth map is back-projected through the tracked
///   camera pose into a coloured voxel cloud, which becomes the point cloud export.
/// - The same frames are fused into a signed distance volume, from which the
///   fine mesh export (down to 5 mm detail) is extracted when the scan ends.
/// - ARKit's own scene reconstruction (a few centimetres resolution) is shown
///   live as a wireframe, and is the fallback mesh if fusion finds no surface.
final class LiDARScanner: NSObject, ObservableObject, ARSessionDelegate {
    struct Settings: Equatable {
        /// Depth beyond this is ignored, which crops the background away.
        var maxDistance: Float = 2.0
        /// Edge length of the point-cloud and mesh voxels in metres.
        var voxelSize: Float = 0.005
        /// Keep only high-confidence LiDAR samples (cleaner, slightly sparser).
        var highConfidenceOnly = true
    }

    enum Phase: Equatable {
        case ready
        case scanning
        case paused
        case processing
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var pointCount = 0
    @Published private(set) var trackingHint: String?
    @Published var settings = Settings() {
        didSet { applySettings() }
    }

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            && ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    private weak var session: ARSession?
    // Everything below is touched only on `queue`, which is also the ARSession
    // delegate queue, so frames are processed without hopping threads.
    private let queue = DispatchQueue(label: "facet.lidar", qos: .userInitiated)
    private var cloud = VoxelCloud(voxelSize: 0.005)
    private var capturing = false
    private var lastIntegration: TimeInterval = 0
    private var integration = VoxelCloud.IntegrationOptions(step: 1, minDepth: 0.15, maxDepth: 2.0, minConfidence: 2,
                                                             maxNeighborJump: 0.04)
    private var lastHint: String?
    private var meshBusy = false

    // The mesh volume is fused on its own queue so a slow frame never holds up
    // ARKit; frames that arrive while it's busy are left out of the mesh (they
    // still go into the point cloud). `volume` is touched only on `meshQueue`.
    private let meshQueue = DispatchQueue(label: "facet.lidar.mesh", qos: .userInitiated)
    private var volume = TSDFVolume(voxelSize: 0.005)

    /// Integration rate. LiDAR depth is 60 Hz but neighbouring frames are near
    /// duplicates; ~6 Hz keeps the CPU cool and loses nothing.
    private let integrationInterval: TimeInterval = 0.16

    @MainActor
    func attach(to arView: ARView) {
        arView.automaticallyConfigureSession = false
        arView.renderOptions.insert(.disableMotionBlur)
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.session.delegateQueue = queue
        arView.session.delegate = self
        session = arView.session
        arView.session.run(Self.configuration())
    }

    private static func configuration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.environmentTexturing = .none
        return config
    }

    func start() {
        phase = .scanning
        queue.async { self.capturing = true }
    }

    func pause() {
        phase = .paused
        queue.async { self.capturing = false }
    }

    /// Clears everything captured so far and restarts tracking.
    func reset() {
        let voxelSize = settings.voxelSize
        queue.async {
            self.capturing = false
            self.cloud = VoxelCloud(voxelSize: voxelSize)
            self.meshQueue.async { self.volume = TSDFVolume(voxelSize: voxelSize) }
            DispatchQueue.main.async { self.pointCount = 0 }
        }
        phase = .ready
        session?.run(Self.configuration(), options: [.resetTracking, .resetSceneReconstruction, .removeExistingAnchors])
    }

    func stop() {
        session?.pause()
    }

    private func applySettings() {
        let s = settings
        queue.async {
            self.integration.maxDepth = s.maxDistance
            self.integration.minConfidence = s.highConfidenceOnly ? 2 : 1
            // Voxel size can only change before anything is captured.
            if self.cloud.voxelCount == 0 && self.cloud.voxelSize != s.voxelSize {
                self.cloud = VoxelCloud(voxelSize: s.voxelSize)
                self.meshQueue.async { self.volume = TSDFVolume(voxelSize: s.voxelSize) }
            }
        }
    }

    // MARK: ARSessionDelegate (on `queue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        updateHint(for: frame.camera.trackingState)
        guard capturing, case .normal = frame.camera.trackingState,
              frame.timestamp - lastIntegration >= integrationInterval,
              let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        lastIntegration = frame.timestamp
        integrate(frame: frame, sceneDepth: sceneDepth)
        let count = cloud.voxelCount
        DispatchQueue.main.async { self.pointCount = count }
    }

    private func integrate(frame: ARFrame, sceneDepth: ARDepthData) {
        guard let depth = DepthImage(depthMap: sceneDepth.depthMap),
              let sampler = YCbCrSampler(frame.capturedImage) else { return }
        let confidence = sceneDepth.confidenceMap.map(copyBytes(of:))

        // ARKit's intrinsics are for the full-size colour image; the depth map
        // covers the same field of view at lower resolution.
        let sx = Float(depth.width) / Float(sampler.width)
        let sy = Float(depth.height) / Float(sampler.height)
        let intrinsics = Intrinsics(frame.camera.intrinsics).scaled(x: sx, y: sy)
        let toColorX = Float(sampler.width) / Float(depth.width)
        let toColorY = Float(sampler.height) / Float(depth.height)

        // Colour at depth resolution, copied so the camera image is released
        // before the mesh volume (on another queue) uses it.
        let width = depth.width
        var buffer = [SIMD3<UInt8>](repeating: .zero, count: width * depth.height)
        for y in 0..<depth.height {
            for x in 0..<width {
                buffer[y * width + x] = sampler.rgb(x: Int((Float(x) + 0.5) * toColorX), y: Int((Float(y) + 0.5) * toColorY))
            }
        }
        sampler.unlock()
        let rgb = buffer
        let color: ColorSampler = { x, y in rgb[y * width + x] }
        let pose = RigidTransform(frame.camera.transform)

        cloud.integrate(depth: depth, confidence: confidence, intrinsics: intrinsics,
                        cameraToWorld: pose, options: integration, color: color)

        guard !meshBusy else { return }
        meshBusy = true
        // For the volume, step only thins the search for blocks near the surface.
        let options = VoxelCloud.IntegrationOptions(step: 2, minDepth: integration.minDepth,
                                                    maxDepth: integration.maxDepth,
                                                    minConfidence: integration.minConfidence,
                                                    maxNeighborJump: integration.maxNeighborJump)
        meshQueue.async {
            self.volume.integrate(depth: depth, confidence: confidence, intrinsics: intrinsics,
                                  cameraToWorld: pose, options: options, color: color)
            self.queue.async { self.meshBusy = false }
        }
    }

    private func updateHint(for state: ARCamera.TrackingState) {
        let hint: String?
        switch state {
        case .normal: hint = nil
        case .notAvailable: hint = "Tracking unavailable"
        case .limited(.initializing): hint = "Move the phone slowly to start tracking"
        case .limited(.excessiveMotion): hint = "Slow down"
        case .limited(.insufficientFeatures): hint = "Point at something with more detail"
        case .limited(.relocalizing): hint = "Return to where you started"
        case .limited: hint = "Tracking limited"
        }
        guard hint != lastHint else { return }
        lastHint = hint
        DispatchQueue.main.async { self.trackingHint = hint }
    }

    // MARK: Finishing

    struct Result {
        var mesh: Mesh
        var points: Mesh
    }

    /// Stops capturing and builds the exports. Returns nil if nothing usable
    /// was captured.
    @MainActor
    func finish() async -> Result? {
        phase = .processing
        // Snapshot ARKit's mesh on the main thread while the session is live.
        let anchors = session?.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        let reconstructed = anchors.reduce(into: Mesh()) { mesh, anchor in mesh.append(Mesh(anchor)) }
        session?.pause()

        let result: Result? = await withCheckedContinuation { continuation in
            queue.async {
                self.capturing = false
                // Voxels seen fewer than three times are mostly sensor noise.
                let points = self.cloud.pointCloud(minObservations: 3)
                guard !points.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                // Fallback: ARKit's coarse mesh, coloured from the cloud and trimmed
                // to what was seen within range. It sits a centimetre or two off the
                // depth samples, so the reach is in metres rather than voxels.
                let coarse = self.cloud.colorizeAndCrop(reconstructed, maxDistance: 0.03)
                    .removingSmallComponents(minTriangles: 30)
                // `meshQueue` is serial, so this runs after any fusion still in flight.
                self.meshQueue.async {
                    // Drop floating fragments smaller than about 20 cm².
                    let voxel = self.volume.voxelSize
                    let fused = self.volume.extractMesh(minWeight: 2)
                        .removingSmallComponents(minTriangles: max(20, Int(0.004 / (voxel * voxel))))
                    continuation.resume(returning: Result(mesh: fused.isEmpty ? coarse : fused, points: points))
                }
            }
        }
        if result == nil { resumeAfterFailedFinish() }
        return result
    }

    /// Returns to a paused, resumable scan after Done produced nothing or the
    /// save failed. Keeps the tracked map and everything captured so far.
    @MainActor
    func resumeAfterFailedFinish() {
        phase = .paused
        session?.run(Self.configuration())
    }
}

extension Mesh {
    /// Copies an ARKit reconstruction chunk into world space.
    init(_ anchor: ARMeshAnchor) {
        self.init()
        let geometry = anchor.geometry
        let transform = RigidTransform(anchor.transform)

        let vertices = geometry.vertices
        let vertexBase = UnsafeRawPointer(vertices.buffer.contents()).advanced(by: vertices.offset)
        positions.reserveCapacity(vertices.count)
        for i in 0..<vertices.count {
            let p = vertexBase.advanced(by: i * vertices.stride)
            let local = SIMD3<Float>(p.load(as: Float.self),
                                     p.load(fromByteOffset: 4, as: Float.self),
                                     p.load(fromByteOffset: 8, as: Float.self))
            positions.append(transform.apply(local))
        }

        let faces = geometry.faces
        guard faces.indexCountPerPrimitive == 3 else { return }
        let faceBase = UnsafeRawPointer(faces.buffer.contents())
        let indexCount = faces.count * 3
        indices.reserveCapacity(indexCount)
        for i in 0..<indexCount {
            if faces.bytesPerIndex == 4 {
                indices.append(faceBase.load(fromByteOffset: i * 4, as: UInt32.self))
            } else {
                indices.append(UInt32(faceBase.load(fromByteOffset: i * 2, as: UInt16.self)))
            }
        }
    }
}
