import ARKit
import Foundation
import RealityKit
import ScanCore

/// Rear LiDAR scanning for rooms, bodies, furniture and other larger objects.
///
/// Two things are built at once while the user walks around the subject:
/// - ARKit's own scene reconstruction supplies the triangle mesh (watertight-ish,
///   a few centimetres resolution), shown live as a wireframe.
/// - Every few frames the LiDAR depth map is back-projected through the tracked
///   camera pose into a coloured voxel cloud, which becomes the dense point
///   cloud export and also colours and trims the mesh to the chosen range.
final class LiDARScanner: NSObject, ObservableObject, ARSessionDelegate {
    struct Settings: Equatable {
        /// Depth beyond this is ignored, which crops the background away.
        var maxDistance: Float = 2.0
        /// Edge length of the point-cloud voxels in metres.
        var voxelSize: Float = 0.01
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
    private var cloud = VoxelCloud(voxelSize: 0.01)
    private var capturing = false
    private var lastIntegration: TimeInterval = 0
    private var integration = VoxelCloud.IntegrationOptions(step: 2, minDepth: 0.15, maxDepth: 2.0, minConfidence: 2)
    private var lastHint: String?

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
              let colors = YCbCrSampler(frame.capturedImage) else { return }
        defer { colors.unlock() }
        let confidence = sceneDepth.confidenceMap.map(copyBytes(of:))

        // ARKit's intrinsics are for the full-size colour image; the depth map
        // covers the same field of view at lower resolution.
        let sx = Float(depth.width) / Float(colors.width)
        let sy = Float(depth.height) / Float(colors.height)
        let intrinsics = Intrinsics(frame.camera.intrinsics).scaled(x: sx, y: sy)
        let toColorX = Float(colors.width) / Float(depth.width)
        let toColorY = Float(colors.height) / Float(depth.height)

        cloud.integrate(depth: depth, confidence: confidence, intrinsics: intrinsics,
                        cameraToWorld: RigidTransform(frame.camera.transform),
                        options: integration) { x, y in
            colors.rgb(x: Int((Float(x) + 0.5) * toColorX), y: Int((Float(y) + 0.5) * toColorY))
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
                let points = self.cloud.pointCloud(minObservations: 2)
                guard !points.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                // Colour the mesh from the cloud and drop parts never seen within range,
                // then clear away small floating fragments.
                let mesh = self.cloud.colorizeAndCrop(reconstructed, searchRadius: 2)
                    .removingSmallComponents(minTriangles: 30)
                continuation.resume(returning: Result(mesh: mesh, points: points))
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
