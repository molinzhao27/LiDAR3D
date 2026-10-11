import Foundation
import Network
import ScanCore
import UIKit

/// A tiny HTTP server so any computer on the same Wi-Fi can download scans
/// from a browser. It only serves files from the scans folder, read-only,
/// and only while the user has it switched on.
@MainActor
final class WiFiShareServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var address: String?
    @Published private(set) var errorMessage: String?

    let port: UInt16 = 8080
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "facet.wifi-share")

    func start() {
        guard listener == nil else { return }
        errorMessage = nil
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { connection in
                HTTPConnection(connection: connection).start(on: DispatchQueue(label: "facet.wifi-share.connection"))
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handle(state) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            errorMessage = "Couldn't start sharing: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        address = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            if let ip = Self.wifiAddress() {
                address = "http://\(ip):\(port)"
            } else {
                address = nil
                errorMessage = "Connect this device to Wi-Fi to share scans."
            }
            // Keep the screen on so the server isn't suspended mid-download.
            UIApplication.shared.isIdleTimerDisabled = true
        case .failed(let error):
            errorMessage = "Sharing stopped: \(error.localizedDescription)"
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    /// IPv4 address of the Wi-Fi interface (en0), or of the personal hotspot
    /// bridge when the phone itself is the access point.
    nonisolated static func wifiAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: [String: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found[name] = String(cString: host)
            }
        }
        return found["en0"] ?? found.first(where: { $0.key.hasPrefix("bridge") })?.value
    }
}

/// Handles one browser request, then closes the connection.
private final class HTTPConnection {
    private let connection: NWConnection
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            do {
                if let request = try MiniHTTP.parseRequest(buffer) {
                    respond(to: request)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive()
                }
            } catch {
                send(status: 400, reason: "Bad Request", text: "Bad request")
            }
        }
    }

    private func respond(to request: MiniHTTP.Request) {
        guard request.method == "GET" || request.method == "HEAD" else {
            send(status: 405, reason: "Method Not Allowed", text: "Only GET is supported")
            return
        }
        let includeBody = request.method == "GET"
        switch MiniHTTP.route(request.path) {
        case .index:
            let scans = ScanStore.loadAll().map { record in
                MiniHTTP.ListedScan(name: record.id, files: record.exports.map { url in
                    (url.lastPathComponent, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                })
            }
            let page = Data(MiniHTTP.indexPage(appName: "Facet scans", scans: scans).utf8)
            send(head: MiniHTTP.responseHead(status: 200, reason: "OK", contentType: "text/html; charset=utf-8",
                                             contentLength: page.count),
                 body: includeBody ? page : nil)
        case .file(let scan, let name):
            let url = ScanStore.root.appendingPathComponent(scan).appendingPathComponent(name)
            // Only model files are downloadable, never info.json or anything else.
            let allowed = ["ply", "stl"].contains(url.pathExtension.lowercased())
            guard allowed, let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
                send(status: 404, reason: "Not Found", text: "No such file")
                return
            }
            let head = MiniHTTP.responseHead(
                status: 200, reason: "OK", contentType: MiniHTTP.contentType(forFileName: name),
                contentLength: data.count,
                extraHeaders: ["Content-Disposition": "attachment; filename=\"\(name.replacingOccurrences(of: "\"", with: ""))\""])
            send(head: head, body: includeBody ? data : nil)
        case .notFound:
            send(status: 404, reason: "Not Found", text: "Not found")
        }
    }

    private func send(status: Int, reason: String, text: String) {
        let body = Data(text.utf8)
        send(head: MiniHTTP.responseHead(status: status, reason: reason, contentType: "text/plain; charset=utf-8",
                                         contentLength: body.count),
             body: body)
    }

    private func send(head: Data, body: Data?) {
        // Head and body go out as separate sends so a large memory-mapped
        // model file is never copied into one combined buffer.
        connection.send(content: head, completion: .contentProcessed { _ in })
        connection.send(content: body ?? Data(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [self] _ in connection.cancel() })
    }
}
