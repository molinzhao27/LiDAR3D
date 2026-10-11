/// Fuses coloured depth frames from a tracked camera into a sparse voxel grid.
/// Each occupied voxel keeps the mean position and colour of every sample that
/// fell into it, which both de-duplicates overlapping frames and averages noise.
public struct VoxelCloud {
    public let voxelSize: Float
    /// Once this many voxels exist, new space is ignored and only existing
    /// voxels keep refining. Bounds memory on long scans.
    public let maxVoxels: Int

    private var lookup: [SIMD3<Int32>: Int] = [:]
    private var positionSums: [SIMD3<Float>] = []
    private var colorSums: [SIMD3<Float>] = []
    private var counts: [UInt32] = []

    public init(voxelSize: Float, maxVoxels: Int = 3_000_000) {
        precondition(voxelSize > 0)
        self.voxelSize = voxelSize
        self.maxVoxels = maxVoxels
    }

    public var voxelCount: Int { counts.count }
    public var isFull: Bool { counts.count >= maxVoxels }

    @inline(__always)
    func key(for p: SIMD3<Float>) -> SIMD3<Int32> {
        let s = p / voxelSize
        return SIMD3(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
    }

    public mutating func add(_ p: SIMD3<Float>, color: SIMD3<UInt8>) {
        // Reject non-finite points and anything absurdly far (would overflow keys).
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
              abs(p.x) < 10_000, abs(p.y) < 10_000, abs(p.z) < 10_000 else { return }
        let k = key(for: p)
        let c = SIMD3<Float>(Float(color.x), Float(color.y), Float(color.z))
        if let i = lookup[k] {
            positionSums[i] += p
            colorSums[i] += c
            counts[i] &+= 1
        } else if counts.count < maxVoxels {
            lookup[k] = counts.count
            positionSums.append(p)
            colorSums.append(c)
            counts.append(1)
        }
    }

    public struct IntegrationOptions {
        public var step = 2
        public var minDepth: Float = 0.1
        public var maxDepth: Float = 3
        /// Confidence values below this are skipped (ARKit: 0 low, 1 medium, 2 high).
        public var minConfidence: UInt8 = 1

        public init(step: Int = 2, minDepth: Float = 0.1, maxDepth: Float = 3, minConfidence: UInt8 = 1) {
            self.step = step
            self.minDepth = minDepth
            self.maxDepth = maxDepth
            self.minConfidence = minConfidence
        }
    }

    /// Back-projects a depth map seen from `cameraToWorld` and adds every
    /// accepted pixel. `confidence`, if given, is one value per depth pixel.
    /// Returns how many samples were added.
    @discardableResult
    public mutating func integrate(depth image: DepthImage, confidence: [UInt8]? = nil,
                                   intrinsics: Intrinsics, cameraToWorld: RigidTransform,
                                   options: IntegrationOptions = IntegrationOptions(),
                                   color: ColorSampler) -> Int {
        let step = max(1, options.step)
        var added = 0
        var y = 0
        while y < image.height {
            var x = 0
            while x < image.width {
                defer { x += step }
                let i = y * image.width + x
                let z = image.depth[i]
                guard DepthImage.isValid(z), z >= options.minDepth, z <= options.maxDepth else { continue }
                if let confidence, confidence[i] < options.minConfidence { continue }
                let local = intrinsics.unproject(u: Float(x), v: Float(y), depth: z)
                add(cameraToWorld.apply(local), color: color(x, y))
                added += 1
            }
            y += step
        }
        return added
    }

    /// The fused cloud as a coloured point mesh. Voxels hit fewer than
    /// `minObservations` times are treated as noise and left out.
    public func pointCloud(minObservations: Int = 1) -> Mesh {
        var mesh = Mesh()
        mesh.positions.reserveCapacity(counts.count)
        mesh.colors.reserveCapacity(counts.count)
        for i in 0..<counts.count where Int(counts[i]) >= minObservations {
            let n = Float(counts[i])
            mesh.positions.append(positionSums[i] / n)
            let c = colorSums[i] / n
            mesh.colors.append(SIMD3(UInt8(min(255, c.x.rounded())), UInt8(min(255, c.y.rounded())), UInt8(min(255, c.z.rounded()))))
        }
        return mesh
    }

    /// Colour of the observed point closest to `p` within `searchRadius`
    /// voxels in each direction, or nil when nothing was observed nearby.
    public func color(near p: SIMD3<Float>, searchRadius: Int = 1) -> SIMD3<UInt8>? {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
        let k = key(for: p)
        let r = Int32(max(0, searchRadius))
        var best = -1
        var bestDistance = Float.greatestFiniteMagnitude
        for dz in -r...r {
            for dy in -r...r {
                for dx in -r...r {
                    guard let i = lookup[k &+ SIMD3(dx, dy, dz)] else { continue }
                    let d = positionSums[i] / Float(counts[i]) - p
                    let dist = (d * d).sum()
                    if dist < bestDistance {
                        bestDistance = dist
                        best = i
                    }
                }
            }
        }
        guard best >= 0 else { return nil }
        let c = colorSums[best] / Float(counts[best])
        return SIMD3(UInt8(min(255, c.x.rounded())), UInt8(min(255, c.y.rounded())), UInt8(min(255, c.z.rounded())))
    }

    /// Colours every vertex of `mesh` from the cloud. Vertices with no observed
    /// point nearby are removed along with their triangles, which trims the
    /// mesh to what the depth camera actually saw within range.
    public func colorizeAndCrop(_ mesh: Mesh, searchRadius: Int = 2) -> Mesh {
        var colored = mesh
        colored.colors = []
        colored.colors.reserveCapacity(mesh.vertexCount)
        var keep = [Bool](repeating: true, count: mesh.vertexCount)
        for i in 0..<mesh.vertexCount {
            if let c = color(near: mesh.positions[i], searchRadius: searchRadius) {
                colored.colors.append(c)
            } else {
                colored.colors.append(SIMD3(128, 128, 128))
                keep[i] = false
            }
        }
        let cropped = colored.filteringVertices(keep: keep)
        if !mesh.isPointCloud && cropped.indices.isEmpty { return Mesh() }
        return cropped.removingUnreferencedVertices()
    }
}
