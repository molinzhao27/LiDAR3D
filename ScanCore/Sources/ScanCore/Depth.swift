/// A metric depth map (metres, row-major). Zero, negative or non-finite
/// values mean "no measurement".
public struct DepthImage: Equatable {
    public let width: Int
    public let height: Int
    public var depth: [Float]

    public init(width: Int, height: Int, depth: [Float]) {
        precondition(depth.count == width * height, "depth buffer size mismatch")
        self.width = width
        self.height = height
        self.depth = depth
    }

    /// Copies a depth map out of a strided buffer (e.g. a locked CVPixelBuffer).
    public init(width: Int, height: Int, rowStride: Int, data: UnsafePointer<Float>) {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = data + y * rowStride
            for x in 0..<width { values[y * width + x] = row[x] }
        }
        self.init(width: width, height: height, depth: values)
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> Float {
        depth[y * width + x]
    }

    @inline(__always)
    static func isValid(_ z: Float) -> Bool {
        z.isFinite && z > 0
    }
}

/// Supplies an sRGB colour for a pixel of the depth map.
public typealias ColorSampler = (_ x: Int, _ y: Int) -> SIMD3<UInt8>

/// Turns a single depth map into a triangle mesh by connecting neighbouring
/// pixels, skipping triangles that span a depth discontinuity.
public enum DepthMesher {
    public struct Options {
        public var step = 1
        public var minDepth: Float = 0.05
        public var maxDepth: Float = 5
        /// Largest depth jump allowed across one pixel step, relative to depth.
        public var maxRelativeJump: Float = 0.03

        public init(step: Int = 1, minDepth: Float = 0.05, maxDepth: Float = 5, maxRelativeJump: Float = 0.03) {
            self.step = step
            self.minDepth = minDepth
            self.maxDepth = maxDepth
            self.maxRelativeJump = maxRelativeJump
        }
    }

    /// Returns the mesh in camera space (ARKit convention, see
    /// `Intrinsics.unproject`), with triangles facing the camera.
    public static func mesh(from image: DepthImage, intrinsics: Intrinsics, options: Options = Options(),
                            color: ColorSampler? = nil) -> Mesh {
        let step = max(1, options.step)
        let gw = (image.width + step - 1) / step
        let gh = (image.height + step - 1) / step
        var grid = [Int32](repeating: -1, count: gw * gh)
        var gridDepth = [Float](repeating: 0, count: gw * gh)
        var mesh = Mesh()

        for gy in 0..<gh {
            for gx in 0..<gw {
                let x = gx * step, y = gy * step
                let z = image[x, y]
                guard DepthImage.isValid(z), z >= options.minDepth, z <= options.maxDepth else { continue }
                grid[gy * gw + gx] = Int32(mesh.positions.count)
                gridDepth[gy * gw + gx] = z
                mesh.positions.append(intrinsics.unproject(u: Float(x), v: Float(y), depth: z))
                if let color { mesh.colors.append(color(x, y)) }
            }
        }

        let jump = options.maxRelativeJump * Float(step)
        func connected(_ a: Int, _ b: Int, _ c: Int) -> Bool {
            guard grid[a] >= 0, grid[b] >= 0, grid[c] >= 0 else { return false }
            let za = gridDepth[a], zb = gridDepth[b], zc = gridDepth[c]
            let lo = min(za, zb, zc), hi = max(za, zb, zc)
            return hi - lo <= jump * lo
        }

        if gw >= 2 && gh >= 2 {
            for gy in 0..<(gh - 1) {
                for gx in 0..<(gw - 1) {
                    // a b      Image rows grow downwards, camera +y grows upwards,
                    // c d      so (a, c, d) and (a, d, b) wind towards the camera.
                    let a = gy * gw + gx, b = a + 1, c = a + gw, d = c + 1
                    if connected(a, c, d) {
                        mesh.indices += [UInt32(grid[a]), UInt32(grid[c]), UInt32(grid[d])]
                    }
                    if connected(a, d, b) {
                        mesh.indices += [UInt32(grid[a]), UInt32(grid[d]), UInt32(grid[b])]
                    }
                }
            }
        }
        // No surviving triangles means no surface, not a loose cloud of vertices.
        return mesh.indices.isEmpty ? Mesh() : mesh.removingUnreferencedVertices()
    }
}

/// Averages depth over several frames of a still subject to cut sensor noise.
/// Samples that disagree with a pixel's settled mean are rejected as outliers.
public struct DepthAverager {
    public let width: Int
    public let height: Int
    public private(set) var frameCount = 0
    private var sum: [Float]
    private var count: [UInt16]
    /// Relative difference from the running mean beyond which a sample is ignored.
    public var outlierTolerance: Float = 0.03

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        sum = [Float](repeating: 0, count: width * height)
        count = [UInt16](repeating: 0, count: width * height)
    }

    public mutating func add(_ image: DepthImage) {
        precondition(image.width == width && image.height == height, "frame size changed mid-capture")
        for i in 0..<image.depth.count {
            let z = image.depth[i]
            guard DepthImage.isValid(z) else { continue }
            let n = count[i]
            if n >= 3 {
                let mean = sum[i] / Float(n)
                if abs(z - mean) > outlierTolerance * mean { continue }
            }
            if n < UInt16.max {
                sum[i] += z
                count[i] = n + 1
            }
        }
        frameCount += 1
    }

    /// The averaged map; pixels seen in fewer than `minSamples` frames are 0.
    public func result(minSamples: Int = 1) -> DepthImage {
        var out = [Float](repeating: 0, count: width * height)
        for i in 0..<out.count where Int(count[i]) >= max(1, minSamples) {
            out[i] = sum[i] / Float(count[i])
        }
        return DepthImage(width: width, height: height, depth: out)
    }
}
