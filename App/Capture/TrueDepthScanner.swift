import AVFoundation
import Foundation
import ScanCore
import simd

/// Front TrueDepth capture for faces and small close-up objects.
///
/// The subject holds still for about a second while depth frames are averaged
/// (the TrueDepth sensor is noisy frame to frame), then the averaged depth map
/// is meshed and coloured from the matching video frame.
final class TrueDepthScanner: NSObject, ObservableObject, AVCaptureDataOutputSynchronizerDelegate {
    struct Settings: Equatable {
        /// Anything farther than this is treated as background and dropped.
        var maxDistance: Float = 0.6
        /// 1 meshes every depth pixel; 2 every other pixel (lighter files).
        var step = 2
        /// Frames to average.
        var frames = 30
    }

    enum Phase: Equatable {
        case starting
        case ready
        case capturing(progress: Double)
        case processing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .starting
    @Published var settings = Settings()

    let session = AVCaptureSession()

    static var isSupported: Bool {
        AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil
    }

    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var device: AVCaptureDevice?
    private let sessionQueue = DispatchQueue(label: "facet.truedepth.session")
    private let dataQueue = DispatchQueue(label: "facet.truedepth.data", qos: .userInitiated)

    // Touched only on `dataQueue`.
    private var averager: DepthAverager?
    private var intrinsics: Intrinsics?
    private var colorFrame: BGRAImage?
    private var activeSettings = Settings()
    private var continuation: CheckedContinuation<Mesh?, Never>?

    /// Mesh rotation from sensor orientation to portrait-upright.
    /// The front camera's buffers are landscape; this turns the head upright.
    static let portraitCorrection = RigidTransform.rotationZ(-.pi / 2)

    func startSession() {
        sessionQueue.async {
            do {
                try self.configure()
                self.session.startRunning()
                DispatchQueue.main.async { self.phase = .ready }
            } catch {
                DispatchQueue.main.async { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func stopSession() {
        // Release a capture still waiting for frames that will now never come.
        dataQueue.async {
            self.continuation?.resume(returning: nil)
            self.continuation = nil
        }
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private struct SetupError: LocalizedError {
        var errorDescription: String?
    }

    private func configure() throws {
        guard synchronizer == nil else { return }
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            throw SetupError(errorDescription: "This device has no TrueDepth camera.")
        }
        self.device = device

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw SetupError(errorDescription: "Can't use the TrueDepth camera.") }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else { throw SetupError(errorDescription: "Can't read camera video.") }
        session.addOutput(videoOutput)

        depthOutput.isFilteringEnabled = true
        depthOutput.alwaysDiscardsLateDepthData = true
        guard session.canAddOutput(depthOutput) else { throw SetupError(errorDescription: "Can't read depth data.") }
        session.addOutput(depthOutput)
        depthOutput.connection(with: .depthData)?.isEnabled = true

        if let connection = videoOutput.connection(with: .video), connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }

        // Highest-resolution float depth the current video format offers.
        let depthFormats = device.activeFormat.supportedDepthDataFormats.filter {
            let type = CMFormatDescriptionGetMediaSubType($0.formatDescription)
            return type == kCVPixelFormatType_DepthFloat32 || type == kCVPixelFormatType_DepthFloat16
        }
        if let best = depthFormats.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) {
            try device.lockForConfiguration()
            device.activeDepthDataFormat = best
            device.unlockForConfiguration()
        }

        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        synchronizer.setDelegate(self, queue: dataQueue)
        self.synchronizer = synchronizer
    }

    /// Captures and meshes one averaged depth snapshot. The subject should
    /// stay still until it returns.
    @MainActor
    func capture() async -> Mesh? {
        guard phase == .ready else { return nil }
        phase = .capturing(progress: 0)
        let settings = self.settings
        let mesh: Mesh? = await withCheckedContinuation { continuation in
            dataQueue.async {
                self.activeSettings = settings
                self.averager = nil
                self.intrinsics = nil
                self.colorFrame = nil
                self.continuation = continuation
            }
        }
        phase = .ready
        return mesh
    }

    // MARK: AVCaptureDataOutputSynchronizerDelegate (on `dataQueue`)

    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput collection: AVCaptureSynchronizedDataCollection) {
        guard continuation != nil,
              let syncedDepth = collection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
              !syncedDepth.depthDataWasDropped,
              let syncedVideo = collection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !syncedVideo.sampleBufferWasDropped,
              let videoBuffer = CMSampleBufferGetImageBuffer(syncedVideo.sampleBuffer) else { return }

        let depthData = syncedDepth.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        guard let depth = DepthImage(depthMap: depthData.depthDataMap) else { return }

        if averager == nil {
            averager = DepthAverager(width: depth.width, height: depth.height)
            intrinsics = Self.intrinsics(for: depthData, sampleBuffer: syncedVideo.sampleBuffer,
                                         videoBuffer: videoBuffer, depthWidth: depth.width,
                                         depthHeight: depth.height, device: device)
        }
        guard averager?.width == depth.width, averager?.height == depth.height else { return }
        averager?.add(depth)
        let done = averager?.frameCount ?? 0
        // Colour comes from the middle frame, by which time exposure has settled.
        if done == max(1, activeSettings.frames / 2) || colorFrame == nil {
            colorFrame = BGRAImage(videoBuffer) ?? colorFrame
        }

        let progress = Double(done) / Double(activeSettings.frames)
        DispatchQueue.main.async {
            if case .capturing = self.phase { self.phase = .capturing(progress: min(progress, 1)) }
        }
        if done >= activeSettings.frames {
            DispatchQueue.main.async {
                if case .capturing = self.phase { self.phase = .processing }
            }
            let mesh = buildMesh()
            continuation?.resume(returning: mesh)
            continuation = nil
        }
    }

    private func buildMesh() -> Mesh? {
        guard let averager, let intrinsics, let colorFrame else { return nil }
        let averaged = averager.result(minSamples: max(3, activeSettings.frames / 3))
        let sx = Float(colorFrame.width) / Float(averaged.width)
        let sy = Float(colorFrame.height) / Float(averaged.height)
        let options = DepthMesher.Options(step: activeSettings.step, minDepth: 0.1,
                                          maxDepth: activeSettings.maxDistance, maxRelativeJump: 0.02)
        let mesh = DepthMesher.mesh(from: averaged, intrinsics: intrinsics, options: options) { x, y in
            colorFrame.rgb(x: Int((Float(x) + 0.5) * sx), y: Int((Float(y) + 0.5) * sy))
        }
        let cleaned = mesh.removingSmallComponents(minTriangles: 200).transformed(by: Self.portraitCorrection)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Prefers the depth data's own calibration, then the per-frame matrix
    /// attached to the video, then an estimate from the lens field of view.
    private static func intrinsics(for depthData: AVDepthData, sampleBuffer: CMSampleBuffer, videoBuffer: CVPixelBuffer,
                                   depthWidth: Int, depthHeight: Int, device: AVCaptureDevice?) -> Intrinsics {
        if let calibration = depthData.cameraCalibrationData {
            let reference = calibration.intrinsicMatrixReferenceDimensions
            return Intrinsics(calibration.intrinsicMatrix)
                .scaled(x: Float(depthWidth) / Float(reference.width), y: Float(depthHeight) / Float(reference.height))
        }
        if let attachment = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                            attachmentModeOut: nil) as? Data,
           attachment.count >= MemoryLayout<matrix_float3x3>.size {
            let k = attachment.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
            let vw = Float(CVPixelBufferGetWidth(videoBuffer)), vh = Float(CVPixelBufferGetHeight(videoBuffer))
            return Intrinsics(k).scaled(x: Float(depthWidth) / vw, y: Float(depthHeight) / vh)
        }
        let fov = device?.activeFormat.videoFieldOfView ?? 60
        return Intrinsics.fromHorizontalFOV(degrees: fov, width: depthWidth, height: depthHeight)
    }
}
