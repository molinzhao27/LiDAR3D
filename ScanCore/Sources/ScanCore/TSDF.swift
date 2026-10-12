/// Fuses depth frames from a tracked camera into a truncated signed distance
/// field (TSDF) and extracts a fine, smooth triangle mesh from it.
///
/// Space is split into blocks of 8×8×8 voxels that are only allocated near
/// observed surfaces, so memory follows the scanned surface rather than its
/// bounding box. Each voxel keeps a weighted running average of its distance
/// to the surface along the camera's view direction (positive in front of the
/// surface, negative behind, divided by the truncation distance) and of the
/// surface colour. Averaging many frames cancels sensor noise, which is what
/// makes the fused surface smooth where single depth frames are rough.
public struct TSDFVolume {
    /// Voxels per block edge. The voxel addressing below (shifts by 3, masks
    /// with 7) relies on this being 8.
    public static let blockSide = 8
    static let voxelsPerBlock = blockSide * blockSide * blockSide

    public let voxelSize: Float
    /// How far either side of the surface each frame updates, in metres.
    public let truncation: Float
    /// Allocation stops once this many blocks exist; existing blocks keep
    /// refining. Bounds memory (about 6 KB per block) on long scans.
    public let maxBlocks: Int
    /// Caps a voxel's weight so later frames can still correct earlier ones.
    public var maxWeight: Float = 64

    private var blockLookup: [SIMD3<Int32>: Int] = [:]
    private var blockKeys: [SIMD3<Int32>] = []
    /// Per voxel, block after block: normalised signed distance in -1...1.
    private var sdf: [Float] = []
    private var weight: [Float] = []
    /// Per voxel: averaged colour in xyz and how many samples it holds in w.
    private var color: [SIMD4<UInt8>] = []

    public init(voxelSize: Float, truncation: Float? = nil, maxBlocks: Int = 16_000) {
        precondition(voxelSize > 0)
        self.voxelSize = voxelSize
        self.truncation = max(truncation ?? 4 * voxelSize, voxelSize)
        self.maxBlocks = maxBlocks
    }

    public var blockCount: Int { blockKeys.count }
    public var isFull: Bool { blockKeys.count >= maxBlocks }

    // MARK: Integration

    /// Fuses one depth map seen from `cameraToWorld`. Pixels are filtered like
    /// `VoxelCloud.integrate` (depth range, confidence, silhouette edges);
    /// `options.step` only thins the search for blocks to update.
    public mutating func integrate(depth image: DepthImage, confidence: [UInt8]? = nil,
                                   intrinsics: Intrinsics, cameraToWorld: RigidTransform,
                                   options: VoxelCloud.IntegrationOptions = VoxelCloud.IntegrationOptions(),
                                   color sampleColor: ColorSampler) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return }

        // Which depth pixels to trust.
        var usable = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let z = image.depth[i]
                guard DepthImage.isValid(z), z >= options.minDepth, z <= options.maxDepth else { continue }
                if let confidence, confidence[i] < options.minConfidence { continue }
                if let jump = options.maxNeighborJump, image.isOnEdge(x: x, y: y, relativeJump: jump) { continue }
                usable[i] = true
            }
        }

        // Blocks within the truncation band around the observed surface,
        // sampled along each pixel's ray at half-block spacing.
        let blockLength = Float(Self.blockSide) * voxelSize
        let bandSamples = max(1, Int((2 * truncation / (blockLength / 2)).rounded(.up)))
        let camera = cameraToWorld.origin
        var touched = Set<SIMD3<Int32>>()
        let step = max(1, options.step)
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                defer { x += step }
                let i = y * w + x
                guard usable[i] else { continue }
                let p = cameraToWorld.apply(intrinsics.unproject(u: Float(x), v: Float(y), depth: image.depth[i]))
                let ray = unitVector(p - camera)
                for s in 0...bandSamples {
                    let t = -truncation + 2 * truncation * Float(s) / Float(bandSamples)
                    if let key = blockKey(containing: p + ray * t) { touched.insert(key) }
                }
            }
            y += step
        }

        // Project every voxel of those blocks into the depth map and blend in
        // its distance to the surface seen there.
        let worldToCamera = cameraToWorld.inverse
        for key in touched {
            guard let block = allocateBlock(key) else { continue }
            let base = key &* Int32(Self.blockSide)
            for n in 0..<Self.voxelsPerBlock {
                let g = base &+ SIMD3(Int32(n & 7), Int32((n >> 3) & 7), Int32(n >> 6))
                let center = (SIMD3<Float>(Float(g.x), Float(g.y), Float(g.z)) + 0.5) * voxelSize
                let c = worldToCamera.apply(center)
                let zc = -c.z
                guard zc >= options.minDepth else { continue }
                let u = intrinsics.fx * c.x / zc + intrinsics.cx
                let v = -intrinsics.fy * c.y / zc + intrinsics.cy
                // Range-check before converting so off-screen voxels can't overflow Int.
                guard u > -0.5, v > -0.5, u < Float(w) - 0.5, v < Float(h) - 0.5 else { continue }
                let px = Int(u.rounded()), py = Int(v.rounded())
                guard usable[py * w + px] else { continue }
                let distance = image.depth[py * w + px] - zc
                guard distance >= -truncation else { continue }

                let index = block * Self.voxelsPerBlock + n
                let w0 = weight[index]
                sdf[index] = (sdf[index] * w0 + min(1, distance / truncation)) / (w0 + 1)
                weight[index] = min(w0 + 1, maxWeight)

                // Colour only from samples near the surface.
                if distance < truncation {
                    let rgb = sampleColor(px, py)
                    let old = color[index]
                    let samples = Float(old.w)
                    func blend(_ a: UInt8, _ b: UInt8) -> UInt8 {
                        UInt8(min(255, ((Float(a) * samples + Float(b)) / (samples + 1)).rounded()))
                    }
                    color[index] = SIMD4(blend(old.x, rgb.x), blend(old.y, rgb.y), blend(old.z, rgb.z),
                                         min(old.w, 29) + 1)
                }
            }
        }
    }

    private func blockKey(containing p: SIMD3<Float>) -> SIMD3<Int32>? {
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
              abs(p.x) < 10_000, abs(p.y) < 10_000, abs(p.z) < 10_000 else { return nil }
        let s = p / voxelSize
        let g = SIMD3(Int32(s.x.rounded(.down)), Int32(s.y.rounded(.down)), Int32(s.z.rounded(.down)))
        return SIMD3(g.x >> 3, g.y >> 3, g.z >> 3)
    }

    private mutating func allocateBlock(_ key: SIMD3<Int32>) -> Int? {
        if let block = blockLookup[key] { return block }
        guard blockKeys.count < maxBlocks else { return nil }
        let block = blockKeys.count
        blockLookup[key] = block
        blockKeys.append(key)
        sdf += repeatElement(1, count: Self.voxelsPerBlock)
        weight += repeatElement(0, count: Self.voxelsPerBlock)
        color += repeatElement(SIMD4<UInt8>(0, 0, 0, 0), count: Self.voxelsPerBlock)
        return block
    }

    // MARK: Mesh extraction

    /// The fused surface as a coloured triangle mesh, built with surface nets:
    /// one vertex in every voxel cell the surface passes through (the average
    /// of where it crosses the cell's edges), and a quad across every crossed
    /// edge joining the four cells around it. Faces point out of the surface,
    /// towards where the camera was. Only voxels observed at least `minWeight`
    /// times are trusted.
    public func extractMesh(minWeight: Float = 2) -> Mesh {
        var mesh = Mesh()
        var cellVertex: [SIMD3<Int32>: UInt32] = [:]
        var cache = BlockCache()
        var corners = CellCorners()
        let side = Int32(Self.blockSide)

        for key in blockKeys {
            let base = key &* side
            for lz in 0..<side {
                for ly in 0..<side {
                    for lx in 0..<side {
                        let cell = base &+ SIMD3(lx, ly, lz)
                        guard let vertex = surfaceVertex(cell, minWeight: minWeight, cache: &cache, corners: &corners)
                        else { continue }
                        cellVertex[cell] = UInt32(mesh.positions.count)
                        mesh.positions.append(vertex.position)
                        mesh.colors.append(vertex.color)
                    }
                }
            }
        }

        for cell in cellVertex.keys {
            for axis in 0..<3 {
                guard let ia = voxel(cell, cache: &cache), let ib = voxel(cell &+ Self.unit[axis], cache: &cache),
                      weight[ia] >= minWeight, weight[ib] >= minWeight else { continue }
                let a = sdf[ia], b = sdf[ib]
                guard (a > 0) != (b > 0), Self.isRealCrossing(a, b) else { continue }
                // The four cells sharing this edge, in counter-clockwise order
                // seen from the +axis side.
                let e1 = Self.unit[(axis + 1) % 3], e2 = Self.unit[(axis + 2) % 3]
                guard let v0 = cellVertex[cell], let v1 = cellVertex[cell &- e1],
                      let v2 = cellVertex[cell &- e1 &- e2], let v3 = cellVertex[cell &- e2] else { continue }
                if a < b {
                    // Inside at `cell`, outside one step along +axis: face +axis.
                    mesh.indices += [v0, v1, v2, v0, v2, v3]
                } else {
                    mesh.indices += [v0, v2, v1, v0, v3, v2]
                }
            }
        }
        return mesh.indices.isEmpty ? Mesh() : mesh.removingUnreferencedVertices()
    }

    /// A sign change between two clamped values (+1 to -1) is a jump between
    /// unrelated surfaces, such as a silhouette edge, not a real crossing.
    @inline(__always)
    private static func isRealCrossing(_ a: Float, _ b: Float) -> Bool {
        abs(a) < 0.999 || abs(b) < 0.999
    }

    private struct BlockCache {
        var key = SIMD3<Int32>(.min, .min, .min)
        var block = -1
    }

    private struct CellCorners {
        var value = [Float](repeating: 0, count: 8)
        var color = [SIMD3<Float>](repeating: .zero, count: 8)
        var hasColor = [Bool](repeating: false, count: 8)
    }

    /// Storage index of the voxel at grid coordinate `g`, if its block exists.
    @inline(__always)
    private func voxel(_ g: SIMD3<Int32>, cache: inout BlockCache) -> Int? {
        let key = SIMD3(g.x >> 3, g.y >> 3, g.z >> 3)
        if key != cache.key {
            cache.key = key
            cache.block = blockLookup[key] ?? -1
        }
        guard cache.block >= 0 else { return nil }
        return cache.block * Self.voxelsPerBlock + Int(g.x & 7) + Int(g.y & 7) * 8 + Int(g.z & 7) * 64
    }

    /// The surface-nets vertex of the cell whose lowest corner is voxel `cell`,
    /// or nil when the surface doesn't pass through it.
    private func surfaceVertex(_ cell: SIMD3<Int32>, minWeight: Float, cache: inout BlockCache,
                               corners: inout CellCorners) -> (position: SIMD3<Float>, color: SIMD3<UInt8>)? {
        var hasPositive = false, hasNegative = false
        for k in 0..<8 {
            guard let i = voxel(cell &+ Self.cornerOffset[k], cache: &cache), weight[i] >= minWeight else { return nil }
            let value = sdf[i]
            corners.value[k] = value
            if value > 0 { hasPositive = true } else { hasNegative = true }
            let c = color[i]
            corners.hasColor[k] = c.w > 0
            corners.color[k] = SIMD3(Float(c.x), Float(c.y), Float(c.z))
        }
        guard hasPositive, hasNegative else { return nil }

        var pointSum = SIMD3<Float>.zero, crossings = 0
        var colorSum = SIMD3<Float>.zero, colorCount = 0
        for (a, b) in Self.cellEdges {
            let va = corners.value[a], vb = corners.value[b]
            guard (va > 0) != (vb > 0), Self.isRealCrossing(va, vb) else { continue }
            let t = va / (va - vb)
            pointSum += Self.cornerPoint[a] + (Self.cornerPoint[b] - Self.cornerPoint[a]) * t
            crossings += 1
            switch (corners.hasColor[a], corners.hasColor[b]) {
            case (true, true): colorSum += corners.color[a] + (corners.color[b] - corners.color[a]) * t
            case (true, false): colorSum += corners.color[a]
            case (false, true): colorSum += corners.color[b]
            case (false, false): continue
            }
            colorCount += 1
        }
        guard crossings > 0 else { return nil }

        let local = pointSum / Float(crossings)
        let position = (SIMD3<Float>(Float(cell.x), Float(cell.y), Float(cell.z)) + 0.5 + local) * voxelSize
        guard colorCount > 0 else { return (position, SIMD3(128, 128, 128)) }
        let c = colorSum / Float(colorCount)
        return (position, SIMD3(UInt8(min(max(c.x.rounded(), 0), 255)),
                                UInt8(min(max(c.y.rounded(), 0), 255)),
                                UInt8(min(max(c.z.rounded(), 0), 255))))
    }

    /// Cell corner k sits at bit 0 → +x, bit 1 → +y, bit 2 → +z from the cell origin.
    private static let cornerOffset: [SIMD3<Int32>] = (0..<8).map {
        SIMD3(Int32($0 & 1), Int32(($0 >> 1) & 1), Int32(($0 >> 2) & 1))
    }
    private static let cornerPoint: [SIMD3<Float>] = cornerOffset.map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) }
    /// The 12 cell edges as pairs of corners that differ in one axis.
    private static let cellEdges: [(Int, Int)] = {
        var edges: [(Int, Int)] = []
        for a in 0..<8 {
            for bit in [1, 2, 4] where a & bit == 0 { edges.append((a, a | bit)) }
        }
        return edges
    }()
    private static let unit: [SIMD3<Int32>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
}
