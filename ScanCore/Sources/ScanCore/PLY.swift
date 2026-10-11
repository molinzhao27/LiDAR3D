import Foundation

/// Stanford PLY reading and writing.
///
/// Writes binary little-endian files with float positions, optional uchar
/// colours and int triangle lists, which MeshLab, Blender, CloudCompare and
/// slicers all read. Reads binary little-endian and ASCII files with any
/// numeric property types, picking out x/y/z, red/green/blue and the face list.
public enum PLY {
    public enum DecodeError: Error, Equatable {
        case missingHeader
        case unsupportedFormat(String)
        case malformedHeader(String)
        case missingPositions
        case truncated
        case indexOutOfRange
    }

    // MARK: Writing

    public static func encode(_ mesh: Mesh, comment: String? = nil) -> Data {
        var header = "ply\nformat binary_little_endian 1.0\n"
        if let comment {
            for line in comment.split(separator: "\n") { header += "comment \(line)\n" }
        }
        header += "element vertex \(mesh.vertexCount)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        if mesh.hasColors {
            header += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        }
        if !mesh.isPointCloud {
            header += "element face \(mesh.triangleCount)\n"
            header += "property list uchar int vertex_indices\n"
        }
        header += "end_header\n"

        var out = ByteWriter(capacity: header.utf8.count + mesh.vertexCount * 15 + mesh.triangleCount * 13)
        out.append(contentsOf: Array(header.utf8))
        for i in 0..<mesh.vertexCount {
            let p = mesh.positions[i]
            out.append(p.x)
            out.append(p.y)
            out.append(p.z)
            if mesh.hasColors {
                let c = mesh.colors[i]
                out.append(c.x)
                out.append(c.y)
                out.append(c.z)
            }
        }
        var t = 0
        while t + 2 < mesh.indices.count {
            out.append(UInt8(3))
            out.append(Int32(bitPattern: mesh.indices[t]))
            out.append(Int32(bitPattern: mesh.indices[t + 1]))
            out.append(Int32(bitPattern: mesh.indices[t + 2]))
            t += 3
        }
        return Data(out.bytes)
    }

    // MARK: Reading

    public static func decode(_ data: Data) throws -> Mesh {
        let bytes = [UInt8](data)
        guard let headerEnd = findHeaderEnd(bytes) else { throw DecodeError.missingHeader }
        let headerText = String(decoding: bytes[0..<headerEnd.textEnd], as: UTF8.self)
        let header = try parseHeader(headerText)

        var reader: ValueReader
        switch header.format {
        case "binary_little_endian": reader = BinaryReader(bytes: bytes, offset: headerEnd.bodyStart)
        case "ascii": reader = AsciiReader(bytes: bytes, offset: headerEnd.bodyStart)
        default: throw DecodeError.unsupportedFormat(header.format)
        }

        var mesh = Mesh()
        for element in header.elements {
            switch element.name {
            case "vertex":
                try readVertices(element, into: &mesh, reader: &reader)
            case "face":
                try readFaces(element, into: &mesh, reader: &reader)
            default:
                // Skip unknown elements so files with extra data still load.
                for _ in 0..<element.count {
                    for property in element.properties { try skip(property, reader: &reader) }
                }
            }
        }
        if mesh.indices.contains(where: { Int($0) >= mesh.vertexCount }) { throw DecodeError.indexOutOfRange }
        return mesh
    }

    private static func readVertices(_ element: Element, into mesh: inout Mesh, reader: inout ValueReader) throws {
        let names = element.properties.map(\.name)
        guard names.contains("x"), names.contains("y"), names.contains("z") else { throw DecodeError.missingPositions }
        let hasColor = names.contains("red") && names.contains("green") && names.contains("blue")
        mesh.positions.reserveCapacity(element.count)
        if hasColor { mesh.colors.reserveCapacity(element.count) }
        for _ in 0..<element.count {
            var p = SIMD3<Float>(0, 0, 0)
            var c = SIMD3<UInt8>(0, 0, 0)
            for property in element.properties {
                if property.isList {
                    try skip(property, reader: &reader)
                    continue
                }
                let value = try reader.read(property.type)
                switch property.name {
                case "x": p.x = Float(value)
                case "y": p.y = Float(value)
                case "z": p.z = Float(value)
                case "red": c.x = colorByte(value, type: property.type)
                case "green": c.y = colorByte(value, type: property.type)
                case "blue": c.z = colorByte(value, type: property.type)
                default: break
                }
            }
            mesh.positions.append(p)
            if hasColor { mesh.colors.append(c) }
        }
    }

    private static func readFaces(_ element: Element, into mesh: inout Mesh, reader: inout ValueReader) throws {
        for _ in 0..<element.count {
            for property in element.properties {
                guard property.isList, property.name == "vertex_indices" || property.name == "vertex_index" else {
                    try skip(property, reader: &reader)
                    continue
                }
                let n = try listCount(property, reader: &reader)
                var polygon = [UInt32]()
                polygon.reserveCapacity(n)
                for _ in 0..<n {
                    let v = try reader.read(property.type)
                    guard v.isFinite, v >= 0, v <= Double(UInt32.max) else { throw DecodeError.indexOutOfRange }
                    polygon.append(UInt32(v))
                }
                // Fan-triangulate polygons with more than three corners.
                if n >= 3 {
                    for k in 1..<(n - 1) {
                        mesh.indices += [polygon[0], polygon[k], polygon[k + 1]]
                    }
                }
            }
        }
    }

    private static func skip(_ property: Property, reader: inout ValueReader) throws {
        if property.isList {
            let n = try listCount(property, reader: &reader)
            for _ in 0..<n { _ = try reader.read(property.type) }
        } else {
            _ = try reader.read(property.type)
        }
    }

    private static func listCount(_ property: Property, reader: inout ValueReader) throws -> Int {
        let n = try reader.read(property.countType)
        guard n.isFinite, n >= 0, n <= Double(Int32.max) else { throw DecodeError.truncated }
        return Int(n)
    }

    private static func colorByte(_ value: Double, type: ScalarType) -> UInt8 {
        // Float colours are 0...1; integer colours are 0...255.
        let scaled = type.isFloat ? value * 255 : value
        return UInt8(max(0, min(255, scaled.rounded())))
    }

    // MARK: Header

    enum ScalarType: Equatable {
        case int8, uint8, int16, uint16, int32, uint32, float32, float64

        init?(_ name: String) {
            switch name {
            case "char", "int8": self = .int8
            case "uchar", "uint8": self = .uint8
            case "short", "int16": self = .int16
            case "ushort", "uint16": self = .uint16
            case "int", "int32": self = .int32
            case "uint", "uint32": self = .uint32
            case "float", "float32": self = .float32
            case "double", "float64": self = .float64
            default: return nil
            }
        }

        var size: Int {
            switch self {
            case .int8, .uint8: return 1
            case .int16, .uint16: return 2
            case .int32, .uint32, .float32: return 4
            case .float64: return 8
            }
        }

        var isFloat: Bool { self == .float32 || self == .float64 }
    }

    struct Property {
        var name: String
        var type: ScalarType
        var isList = false
        var countType: ScalarType = .uint8
    }

    struct Element {
        var name: String
        var count: Int
        var properties: [Property] = []
    }

    struct Header {
        var format = ""
        var elements: [Element] = []
    }

    private static func findHeaderEnd(_ bytes: [UInt8]) -> (textEnd: Int, bodyStart: Int)? {
        let marker = Array("end_header".utf8)
        guard bytes.count >= 3, bytes[0] == UInt8(ascii: "p"), bytes[1] == UInt8(ascii: "l"), bytes[2] == UInt8(ascii: "y") else {
            return nil
        }
        var i = 0
        let limit = min(bytes.count, 64 * 1024) - marker.count
        while i <= limit {
            if bytes[i] == marker[0], Array(bytes[i..<(i + marker.count)]) == marker,
               i == 0 || bytes[i - 1] == UInt8(ascii: "\n") {
                var j = i + marker.count
                while j < bytes.count, bytes[j] == UInt8(ascii: "\r") || bytes[j] == UInt8(ascii: " ") { j += 1 }
                guard j < bytes.count, bytes[j] == UInt8(ascii: "\n") else { return nil }
                return (i, j + 1)
            }
            i += 1
        }
        return nil
    }

    static func parseHeader(_ text: String) throws -> Header {
        var header = Header()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let keyword = parts.first else { continue }
            switch keyword {
            case "ply", "comment", "obj_info":
                continue
            case "format":
                guard parts.count >= 2 else { throw DecodeError.malformedHeader(String(rawLine)) }
                header.format = parts[1]
            case "element":
                guard parts.count == 3, let count = Int(parts[2]), count >= 0 else {
                    throw DecodeError.malformedHeader(String(rawLine))
                }
                header.elements.append(Element(name: parts[1], count: count))
            case "property":
                guard !header.elements.isEmpty else { throw DecodeError.malformedHeader(String(rawLine)) }
                if parts.count == 5, parts[1] == "list", let countType = ScalarType(parts[2]), let type = ScalarType(parts[3]) {
                    header.elements[header.elements.count - 1].properties.append(
                        Property(name: parts[4], type: type, isList: true, countType: countType))
                } else if parts.count == 3, let type = ScalarType(parts[1]) {
                    header.elements[header.elements.count - 1].properties.append(Property(name: parts[2], type: type))
                } else {
                    throw DecodeError.malformedHeader(String(rawLine))
                }
            default:
                throw DecodeError.malformedHeader(String(rawLine))
            }
        }
        if header.format.isEmpty { throw DecodeError.malformedHeader("missing format line") }
        return header
    }
}

// MARK: Body readers

protocol ValueReader {
    mutating func read(_ type: PLY.ScalarType) throws -> Double
}

struct BinaryReader: ValueReader {
    let bytes: [UInt8]
    var offset: Int

    init(bytes: [UInt8], offset: Int) {
        self.bytes = bytes
        self.offset = offset
    }

    private mutating func raw<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= bytes.count else { throw PLY.DecodeError.truncated }
        var value: T = 0
        for k in 0..<size {
            value |= T(truncatingIfNeeded: bytes[offset + k]) << (8 * k)
        }
        offset += size
        return value
    }

    mutating func read(_ type: PLY.ScalarType) throws -> Double {
        switch type {
        case .int8: return Double(Int8(bitPattern: try raw(UInt8.self)))
        case .uint8: return Double(try raw(UInt8.self))
        case .int16: return Double(Int16(bitPattern: try raw(UInt16.self)))
        case .uint16: return Double(try raw(UInt16.self))
        case .int32: return Double(Int32(bitPattern: try raw(UInt32.self)))
        case .uint32: return Double(try raw(UInt32.self))
        case .float32: return Double(Float(bitPattern: try raw(UInt32.self)))
        case .float64: return Double(bitPattern: try raw(UInt64.self))
        }
    }
}

struct AsciiReader: ValueReader {
    let bytes: [UInt8]
    var offset: Int

    init(bytes: [UInt8], offset: Int) {
        self.bytes = bytes
        self.offset = offset
    }

    mutating func read(_ type: PLY.ScalarType) throws -> Double {
        while offset < bytes.count, Self.isSpace(bytes[offset]) { offset += 1 }
        let start = offset
        while offset < bytes.count, !Self.isSpace(bytes[offset]) { offset += 1 }
        guard offset > start, let value = Double(String(decoding: bytes[start..<offset], as: UTF8.self)) else {
            throw PLY.DecodeError.truncated
        }
        return value
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09
    }
}

/// Little-endian byte buffer builder shared by the binary writers.
struct ByteWriter {
    var bytes: [UInt8] = []

    init(capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    mutating func append(contentsOf other: [UInt8]) {
        bytes += other
    }

    mutating func append(_ v: UInt8) {
        bytes.append(v)
    }

    mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func append(_ v: Float) {
        append(v.bitPattern)
    }
}
