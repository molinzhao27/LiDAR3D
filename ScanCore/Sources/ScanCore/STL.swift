import Foundation

/// Binary STL writing, the format 3D-printing slicers expect. STL has no
/// colour, so only geometry is written.
public enum STL {
    public static let bytesPerTriangle = 50

    /// Encodes the mesh in metres scaled by `unitScale` (slicers assume
    /// millimetres, so the app passes 1000).
    public static func encode(_ mesh: Mesh, unitScale: Float = 1000, header: String = "cleanroom 3D scanner") -> Data {
        var out = ByteWriter(capacity: 84 + mesh.triangleCount * bytesPerTriangle)
        // 80-byte header. It must not start with "solid" or some readers
        // mistake the file for ASCII STL.
        var headerBytes = Array(header.utf8.prefix(80))
        if headerBytes.starts(with: Array("solid".utf8)) { headerBytes = Array("binary ".utf8) + headerBytes }
        headerBytes = Array(headerBytes.prefix(80))
        headerBytes += [UInt8](repeating: 0, count: 80 - headerBytes.count)
        out.append(contentsOf: headerBytes)
        out.append(UInt32(mesh.triangleCount))

        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[t * 3])] * unitScale
            let b = mesh.positions[Int(mesh.indices[t * 3 + 1])] * unitScale
            let c = mesh.positions[Int(mesh.indices[t * 3 + 2])] * unitScale
            let n = unitVector(crossProduct(b - a, c - a))
            for v in [n, a, b, c] {
                out.append(v.x)
                out.append(v.y)
                out.append(v.z)
            }
            out.append(UInt16(0))
        }
        return Data(out.bytes)
    }

    /// Reads a binary STL back into an unwelded mesh (three vertices per
    /// triangle), converting from `unitScale` units to metres.
    public static func decode(_ data: Data, unitScale: Float = 1000) throws -> Mesh {
        let bytes = [UInt8](data)
        guard bytes.count >= 84 else { throw PLY.DecodeError.truncated }
        var reader = BinaryReader(bytes: bytes, offset: 80)
        let count = Int(try reader.read(.uint32))
        guard bytes.count >= 84 + count * bytesPerTriangle else { throw PLY.DecodeError.truncated }
        var mesh = Mesh()
        mesh.positions.reserveCapacity(count * 3)
        mesh.indices.reserveCapacity(count * 3)
        for _ in 0..<count {
            reader.offset += 12  // stored normal; recomputed on demand instead
            for _ in 0..<3 {
                let x = Float(try reader.read(.float32))
                let y = Float(try reader.read(.float32))
                let z = Float(try reader.read(.float32))
                mesh.indices.append(UInt32(mesh.positions.count))
                mesh.positions.append(SIMD3(x, y, z) / unitScale)
            }
            reader.offset += 2
        }
        return mesh
    }
}
