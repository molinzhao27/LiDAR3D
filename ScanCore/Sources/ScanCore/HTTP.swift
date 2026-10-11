import Foundation

/// The small amount of HTTP/1.1 the on-device Wi-Fi share page needs:
/// parse a GET request line, route it, and build response headers.
public enum MiniHTTP {
    public struct Request: Equatable {
        public var method: String
        public var path: String
    }

    public enum Route: Equatable {
        /// The index page listing every scan.
        case index
        /// A file inside a scan folder: `/files/<scan>/<file>`.
        case file(scan: String, name: String)
        case notFound
    }

    /// Returns the request once the full header block has arrived, nil if more
    /// bytes are needed. Throws on anything that is not a sane request.
    public static func parseRequest(_ data: Data) throws -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16 * 1024 { throw ParseError.headerTooLarge }
            return nil
        }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        guard let line = head.components(separatedBy: "\r\n").first else { throw ParseError.malformed }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw ParseError.malformed }
        var target = String(parts[1])
        if let q = target.firstIndex(of: "?") { target = String(target[..<q]) }
        return Request(method: String(parts[0]), path: target)
    }

    public enum ParseError: Error {
        case malformed
        case headerTooLarge
    }

    public static func route(_ path: String) -> Route {
        if path == "/" || path == "/index.html" { return .index }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // ["", "files", scan, name]
        guard segments.count == 4, segments[0].isEmpty, segments[1] == "files",
              let scan = segments[2].removingPercentEncoding, let name = segments[3].removingPercentEncoding,
              isSafeComponent(scan), isSafeComponent(name) else { return .notFound }
        return .file(scan: scan, name: name)
    }

    /// Rejects anything that could escape the scans directory.
    public static func isSafeComponent(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\\") && !s.contains("\0")
            && !s.hasPrefix(".")
    }

    public static func responseHead(status: Int, reason: String, contentType: String, contentLength: Int,
                                    extraHeaders: [String: String] = [:]) -> Data {
        var s = "HTTP/1.1 \(status) \(reason)\r\n"
        s += "Content-Type: \(contentType)\r\n"
        s += "Content-Length: \(contentLength)\r\n"
        s += "Connection: close\r\n"
        s += "Cache-Control: no-store\r\n"
        for key in extraHeaders.keys.sorted() { s += "\(key): \(extraHeaders[key]!)\r\n" }
        s += "\r\n"
        return Data(s.utf8)
    }

    public static func contentType(forFileName name: String) -> String {
        switch name.split(separator: ".").last?.lowercased() {
        case "ply": return "application/octet-stream"
        case "stl": return "model/stl"
        case "obj": return "model/obj"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        default: return "application/octet-stream"
        }
    }

    public static func percentEncodePathComponent(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public struct ListedScan {
        public var name: String
        public var files: [(name: String, bytes: Int)]

        public init(name: String, files: [(name: String, bytes: Int)]) {
            self.name = name
            self.files = files
        }
    }

    /// The download page served at `/`.
    public static func indexPage(appName: String, scans: [ListedScan]) -> String {
        var rows = ""
        for scan in scans {
            rows += "<section><h2>\(htmlEscape(scan.name))</h2><ul>"
            for file in scan.files {
                let href = "/files/\(percentEncodePathComponent(scan.name))/\(percentEncodePathComponent(file.name))"
                rows += "<li><a href=\"\(href)\" download>\(htmlEscape(file.name))</a> <span>\(formatBytes(file.bytes))</span></li>"
            }
            rows += "</ul></section>"
        }
        if scans.isEmpty { rows = "<p>No scans yet. Make one in the app, then reload this page.</p>" }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(htmlEscape(appName))</title>
        <style>
        :root{color-scheme:light dark;font-family:-apple-system,system-ui,sans-serif}
        body{max-width:720px;margin:2rem auto;padding:0 16px;line-height:1.5}
        section{border:1px solid #8884;border-radius:12px;padding:4px 16px;margin:12px 0}
        h2{font-size:1.05rem;margin:.6rem 0}ul{padding-left:1.1rem}span{opacity:.6;font-size:.9em}
        </style></head><body>
        <h1>\(htmlEscape(appName))</h1>
        \(rows)
        </body></html>
        """
    }

    public static func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        let units = ["KB", "MB", "GB"]
        var value = Double(n) / 1024
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: "%.1f", value) + " " + units[unit]
    }
}
