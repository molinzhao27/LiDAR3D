import Foundation
import ScanCore

enum ScanKind: String, Codable {
    case lidar
    case trueDepth

    var title: String {
        switch self {
        case .lidar: return "LiDAR scan"
        case .trueDepth: return "TrueDepth scan"
        }
    }

    var symbol: String {
        switch self {
        case .lidar: return "cube.transparent"
        case .trueDepth: return "face.dashed"
        }
    }
}

/// Written next to the model files as `info.json`.
struct ScanInfo: Codable, Hashable {
    var kind: ScanKind
    var created: Date
    var vertexCount: Int
    var triangleCount: Int
    var pointCount: Int
}

struct ScanRecord: Identifiable, Hashable {
    /// Folder name inside Documents; also the prefix of every file in it.
    let id: String
    let folder: URL
    let info: ScanInfo

    var meshPLY: URL { folder.appendingPathComponent("\(id)_mesh.ply") }
    var meshSTL: URL { folder.appendingPathComponent("\(id)_mesh.stl") }
    var pointsPLY: URL { folder.appendingPathComponent("\(id)_points.ply") }

    /// Model files that actually exist, in display order.
    var exports: [URL] {
        [meshPLY, meshSTL, pointsPLY].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var hasMesh: Bool { FileManager.default.fileExists(atPath: meshPLY.path) }
    var hasPoints: Bool { FileManager.default.fileExists(atPath: pointsPLY.path) }
}

/// Scans live in the app's Documents folder, one subfolder per scan, so they
/// also show up in the Files app and Finder/iTunes file sharing.
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [ScanRecord] = []

    nonisolated static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() {
        reload()
    }

    func reload() {
        scans = Self.loadAll()
    }

    func delete(_ scan: ScanRecord) {
        try? FileManager.default.removeItem(at: scan.folder)
        reload()
    }

    nonisolated static func loadAll() -> [ScanRecord] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { folder -> ScanRecord? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("info.json")),
                  let info = try? decoder.decode(ScanInfo.self, from: data) else { return nil }
            return ScanRecord(id: folder.lastPathComponent, folder: folder, info: info)
        }
        .sorted { $0.info.created > $1.info.created }
    }

    /// Writes a finished scan to disk. Runs off the main thread: large meshes
    /// take a moment to encode.
    nonisolated static func write(kind: ScanKind, mesh: Mesh?, points: Mesh?) throws -> ScanRecord {
        let created = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = "scan-\(formatter.string(from: created))"
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let info = ScanInfo(kind: kind, created: created,
                            vertexCount: mesh?.vertexCount ?? 0,
                            triangleCount: mesh?.triangleCount ?? 0,
                            pointCount: points?.vertexCount ?? 0)
        let record = ScanRecord(id: id, folder: folder, info: info)
        let comment = "Facet \(kind.rawValue) scan \(id); units: metres"

        if let mesh, !mesh.isEmpty {
            try PLY.encode(mesh, comment: comment).write(to: record.meshPLY, options: .atomic)
            if !mesh.isPointCloud {
                try STL.encode(mesh, unitScale: 1000, header: "Facet scan \(id), millimetres")
                    .write(to: record.meshSTL, options: .atomic)
            }
        }
        if let points, !points.isEmpty {
            try PLY.encode(points, comment: comment).write(to: record.pointsPLY, options: .atomic)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // info.json goes last: a folder without it is ignored, so a crash
        // mid-write never shows up as a half-saved scan.
        try encoder.encode(info).write(to: folder.appendingPathComponent("info.json"), options: .atomic)
        return record
    }
}
