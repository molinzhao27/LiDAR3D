/// Indexed triangle mesh with optional per-vertex colour. A mesh with no
/// triangles is treated as a point cloud.
public struct Mesh: Equatable {
    public var positions: [SIMD3<Float>]
    /// Either empty or one colour per position.
    public var colors: [SIMD3<UInt8>]
    /// Three indices per triangle, counter-clockwise when seen from the front.
    public var indices: [UInt32]

    public init(positions: [SIMD3<Float>] = [], colors: [SIMD3<UInt8>] = [], indices: [UInt32] = []) {
        precondition(colors.isEmpty || colors.count == positions.count, "colour count must match vertex count")
        precondition(indices.count % 3 == 0, "indices must describe whole triangles")
        self.positions = positions
        self.colors = colors
        self.indices = indices
    }

    public var vertexCount: Int { positions.count }
    public var triangleCount: Int { indices.count / 3 }
    public var hasColors: Bool { !colors.isEmpty }
    public var isPointCloud: Bool { indices.isEmpty }
    public var isEmpty: Bool { positions.isEmpty }

    /// Axis-aligned bounds, or nil for an empty mesh.
    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard var lo = positions.first else { return nil }
        var hi = lo
        for p in positions {
            lo = pointwiseMin(lo, p)
            hi = pointwiseMax(hi, p)
        }
        return (lo, hi)
    }

    public func faceNormal(_ triangle: Int) -> SIMD3<Float> {
        let a = positions[Int(indices[triangle * 3])]
        let b = positions[Int(indices[triangle * 3 + 1])]
        let c = positions[Int(indices[triangle * 3 + 2])]
        return unitVector(crossProduct(b - a, c - a))
    }

    /// Area-weighted vertex normals. Point clouds get zero normals.
    public func vertexNormals() -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var i = 0
        while i + 2 < indices.count {
            let ia = Int(indices[i]), ib = Int(indices[i + 1]), ic = Int(indices[i + 2])
            let a = positions[ia], b = positions[ib], c = positions[ic]
            // Unnormalised cross product: its length is twice the triangle area.
            let n = crossProduct(b - a, c - a)
            normals[ia] += n
            normals[ib] += n
            normals[ic] += n
            i += 3
        }
        return normals.map(unitVector)
    }

    public func transformed(by t: RigidTransform) -> Mesh {
        var m = self
        m.positions = positions.map(t.apply)
        return m
    }

    /// Concatenates `other` onto this mesh. If only one side has colours the
    /// other side is filled with mid grey so the colour array stays aligned.
    public mutating func append(_ other: Mesh) {
        let offset = UInt32(positions.count)
        if hasColors || other.hasColors {
            let grey = SIMD3<UInt8>(128, 128, 128)
            if !hasColors { colors = Array(repeating: grey, count: positions.count) }
            colors += other.hasColors ? other.colors : Array(repeating: grey, count: other.positions.count)
        }
        positions += other.positions
        indices += other.indices.map { $0 + offset }
    }

    /// Keeps the vertices where `keep[i]` is true. Triangles touching a dropped
    /// vertex are dropped too, and the remaining indices are renumbered.
    public func filteringVertices(keep: [Bool]) -> Mesh {
        precondition(keep.count == positions.count)
        var remap = [Int32](repeating: -1, count: positions.count)
        var out = Mesh()
        out.positions.reserveCapacity(positions.count)
        if hasColors { out.colors.reserveCapacity(positions.count) }
        for i in 0..<positions.count where keep[i] {
            remap[i] = Int32(out.positions.count)
            out.positions.append(positions[i])
            if hasColors { out.colors.append(colors[i]) }
        }
        out.indices.reserveCapacity(indices.count)
        var t = 0
        while t + 2 < indices.count {
            let a = remap[Int(indices[t])], b = remap[Int(indices[t + 1])], c = remap[Int(indices[t + 2])]
            if a >= 0 && b >= 0 && c >= 0 {
                out.indices += [UInt32(a), UInt32(b), UInt32(c)]
            }
            t += 3
        }
        return out
    }

    /// Drops vertices no triangle uses. Point clouds are returned unchanged.
    public func removingUnreferencedVertices() -> Mesh {
        guard !isPointCloud else { return self }
        var used = [Bool](repeating: false, count: positions.count)
        for i in indices { used[Int(i)] = true }
        return filteringVertices(keep: used)
    }

    /// Splits every triangle-connected piece of the mesh and keeps only pieces
    /// with at least `minTriangles` triangles. Removes floating specks.
    public func removingSmallComponents(minTriangles: Int) -> Mesh {
        guard !isPointCloud, minTriangles > 1 else { return self }
        var uf = UnionFind(count: positions.count)
        var t = 0
        while t + 2 < indices.count {
            uf.union(Int(indices[t]), Int(indices[t + 1]))
            uf.union(Int(indices[t]), Int(indices[t + 2]))
            t += 3
        }
        var trianglesPerRoot = [Int: Int]()
        t = 0
        while t < indices.count {
            trianglesPerRoot[uf.find(Int(indices[t])), default: 0] += 1
            t += 3
        }
        var keep = [Bool](repeating: false, count: positions.count)
        for i in 0..<positions.count {
            keep[i] = (trianglesPerRoot[uf.find(i)] ?? 0) >= minTriangles
        }
        return filteringVertices(keep: keep).removingUnreferencedVertices()
    }
}

struct UnionFind {
    private var parent: [Int]
    private var rank: [UInt8]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if rank[ra] < rank[rb] {
            parent[ra] = rb
        } else if rank[ra] > rank[rb] {
            parent[rb] = ra
        } else {
            parent[rb] = ra
            rank[ra] += 1
        }
    }
}
