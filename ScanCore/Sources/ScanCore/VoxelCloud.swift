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
        /// Pixels whose depth differs from a direct neighbour by more than this
        /// fraction of their own depth are skipped. Depth sensors blend the
        /// foreground and background along silhouettes, and those "flying
        /// pixels" otherwise show up as streaks and curtains hanging off the
        /// subject. nil keeps every pixel.
        public var maxNeighborJump: Float?

        public init(step: Int = 2, minDepth: Float = 0.1, maxDepth: Float = 3, minConfidence: UInt8 = 1,
                    maxNeighborJump: Float? = nil) {
            self.step = step
            self.minDepth = minDepth
            self.maxDepth = maxDepth
            self.minConfidence = minConfidence
            self.maxNeighborJump = maxNeighborJump
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
                if let jump = options.maxNeighborJump, image.isOnEdge(x: x, y: y, relativeJump: jump) { continue }
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
        guard let hit = nearestVoxel(to: p, maxRadius: max(0, searchRadius)) else { return nil }
        return averageColor(hit.index)
    }

    /// Colours every vertex of `mesh` from the nearest observed point. Vertices
    /// with no observed point within `maxDistance` metres (default: two voxels)
    /// are removed along with their triangles, which trims the mesh to what the
    /// depth camera actually saw within range. The reach is in metres so the
    /// crop doesn't tighten when the voxels are made finer.
    public func colorizeAndCrop(_ mesh: Mesh, maxDistance: Float? = nil) -> Mesh {
        let reach = max(maxDistance ?? 2 * voxelSize, voxelSize)
        let radius = Int((reach / voxelSize).rounded(.up))

        // One coarse cell per `reach`: a vertex with no occupied cell around it
        // is out of range, found with 27 lookups instead of a full voxel search.
        // Most of ARKit's mesh (walls, floor, far furniture) is rejected here.
        var occupied = Set<SIMD3<Int32>>()
        occupied.reserveCapacity(counts.count)
        for i in 0..<counts.count {
            occupied.insert(Self.cell(of: positionSums[i] / Float(counts[i]), size: reach))
        }

        var colored = mesh
        colored.colors = []
        colored.colors.reserveCapacity(mesh.vertexCount)
        var keep = [Bool](repeating: true, count: mesh.vertexCount)
        for i in 0..<mesh.vertexCount {
            let p = mesh.positions[i]
            if Self.hasNeighbor(of: Self.cell(of: p, size: reach), in: occupied),
               let hit = nearestVoxel(to: p, maxRadius: radius),
               hit.distanceSquared <= reach * reach {
                colored.colors.append(averageColor(hit.index))
            } else {
                colored.colors.append(SIMD3(128, 128, 128))
                keep[i] = false
            }
        }
        let cropped = colored.filteringVertices(keep: keep)
        if !mesh.isPointCloud && cropped.indices.isEmpty { return Mesh() }
        return cropped.removingUnreferencedVertices()
    }

    /// The observed voxel whose mean position is nearest to `p`, searching
    /// shells of voxels outwards from `p`'s own and stopping one shell after
    /// the first hit (close enough for colouring and cropping).
    func nearestVoxel(to p: SIMD3<Float>, maxRadius: Int) -> (index: Int, distanceSquared: Float)? {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
              abs(p.x) < 10_000, abs(p.y) < 10_000, abs(p.z) < 10_000 else { return nil }
        let k = key(for: p)
        var best = -1
        var bestDistance = Float.greatestFiniteMagnitude
        var lastShell = maxRadius
        var r: Int32 = 0
        while r <= Int32(lastShell) {
            for dz in -r...r {
                for dy in -r...r {
                    // Inside the shell only its two x faces need checking.
                    let onFace = abs(dz) == r || abs(dy) == r
                    var dx = -r
                    while dx <= r {
                        if let i = lookup[k &+ SIMD3(dx, dy, dz)] {
                            let d = positionSums[i] / Float(counts[i]) - p
                            let dist = (d * d).sum()
                            if dist < bestDistance {
                                bestDistance = dist
                                best = i
                            }
                        }
                        dx = onFace || dx == r ? dx + 1 : r
                    }
                }
            }
            if best >= 0 { lastShell = min(lastShell, Int(r) + 1) }
            r += 1
        }
        return best >= 0 ? (best, bestDistance) : nil
    }

    private func averageColor(_ i: Int) -> SIMD3<UInt8> {
        let c = colorSums[i] / Float(counts[i])
        return SIMD3(UInt8(min(255, c.x.rounded())), UInt8(min(255, c.y.rounded())), UInt8(min(255, c.z.rounded())))
    }

    private static func cell(of p: SIMD3<Float>, size: Float) -> SIMD3<Int32> {
        let s = p / size
        return SIMD3(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
    }

    private static func hasNeighbor(of c: SIMD3<Int32>, in occupied: Set<SIMD3<Int32>>) -> Bool {
        for dz: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dx: Int32 in -1...1 where occupied.contains(c &+ SIMD3(dx, dy, dz)) {
                    return true
                }
            }
        }
        return false
    }
}
