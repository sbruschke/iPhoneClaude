import Foundation
import UIKit

final class FileServer: ObservableObject {
    @Published var isRunning = false
    @Published var port: UInt = 8080
    @Published var ipAddress: String = "unknown"

    let auth: AuthMiddleware
    private var server: GCDWebServer?
    private let fileOps = FileOperations.shared
    private let pathResolver = PathResolver.shared

    init() {
        self.auth = AuthMiddleware()
        self.ipAddress = Self.getWiFiAddress() ?? "unknown"
    }

    func start() {
        guard !isRunning else { return }

        let webServer = GCDWebServer()
        server = webServer

        registerRoutes(on: webServer)

        let started = webServer.start(withPort: port, bonjourName: nil)
        isRunning = started && webServer.isRunning
        ipAddress = Self.getWiFiAddress() ?? "unknown"
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
    }

    // MARK: - Route Registration

    private func registerRoutes(on server: GCDWebServer) {
        // GET /api/info
        server.addHandler(forMethod: "GET", path: "/api/info", request: GCDWebServerRequest.self) { [weak self] request in
            self?.handleInfo(request: request)
        }

        // GET /api/ls
        server.addHandler(forMethod: "GET", path: "/api/ls", request: GCDWebServerRequest.self) { [weak self] request in
            self?.handleLs(request: request)
        }

        // GET /api/read
        server.addHandler(forMethod: "GET", path: "/api/read", request: GCDWebServerRequest.self) { [weak self] request in
            self?.handleRead(request: request)
        }

        // POST /api/write
        server.addHandler(forMethod: "POST", path: "/api/write", request: GCDWebServerDataRequest.self) { [weak self] request in
            self?.handleWrite(request: request)
        }

        // DELETE /api/delete
        server.addHandler(forMethod: "DELETE", path: "/api/delete", request: GCDWebServerRequest.self) { [weak self] request in
            self?.handleDelete(request: request)
        }

        // POST /api/mkdir
        server.addHandler(forMethod: "POST", path: "/api/mkdir", request: GCDWebServerDataRequest.self) { [weak self] request in
            self?.handleMkdir(request: request)
        }

        // PUT /api/upload?path=... — raw binary upload (no JSON/base64 overhead)
        server.addHandler(forMethod: "PUT", path: "/api/upload", request: GCDWebServerRequest.self) { [weak self] request in
            self?.handleUpload(request: request)
        }

        // POST /api/append?path=... — append raw binary to existing file
        server.addHandler(forMethod: "POST", path: "/api/append", request: GCDWebServerRequest.self) { [weak self] request in
            self?.handleAppend(request: request)
        }
    }

    // MARK: - Route Handlers

    private func handleInfo(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }

        let device = UIDevice.current
        let paths = pathResolver.discoverPaths()

        let response: [String: Any] = [
            "device": [
                "name": device.name,
                "model": device.model,
                "systemName": device.systemName,
                "systemVersion": device.systemVersion
            ],
            "server": [
                "port": port,
                "version": "1.0.0"
            ],
            "paths": paths.map { [
                "label": $0.label,
                "path": $0.path,
                "exists": $0.exists
            ] }
        ]

        return GCDWebServerResponse(jsonObject: response)
    }

    private func handleLs(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }

        guard let path = request.query["path"], !path.isEmpty else {
            return jsonError(400, "Missing 'path' parameter")
        }

        do {
            let entries = try fileOps.listDirectory(path: path)
            let dicts: [[String: Any]] = entries.map {
                [
                    "name": $0.name,
                    "path": $0.path,
                    "isDirectory": $0.isDirectory,
                    "size": $0.size,
                    "modified": $0.modified,
                    "permissions": $0.permissions
                ]
            }
            return GCDWebServerResponse(jsonObject: ["path": path, "entries": dicts] as [String: Any])
        } catch {
            return jsonError(statusCode(for: error), error.localizedDescription)
        }
    }

    private func handleRead(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }

        guard let path = request.query["path"], !path.isEmpty else {
            return jsonError(400, "Missing 'path' parameter")
        }

        do {
            let content = try fileOps.readFile(path: path)
            let dict: [String: Any] = [
                "path": content.path,
                "encoding": content.encoding,
                "content": content.content,
                "size": content.size
            ]
            return GCDWebServerResponse(jsonObject: dict)
        } catch {
            return jsonError(statusCode(for: error), error.localizedDescription)
        }
    }

    private func handleWrite(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }

        guard let dataReq = request as? GCDWebServerDataRequest,
              let json = dataReq.jsonObject as? [String: Any],
              let path = json["path"] as? String else {
            return jsonError(400, "Missing JSON body with 'path' field")
        }

        let content = json["content"] as? String ?? ""
        let encoding = json["encoding"] as? String ?? "utf-8"

        do {
            try fileOps.writeFile(path: path, content: content, encoding: encoding)
            return GCDWebServerResponse(jsonObject: [
                "success": true,
                "path": path
            ] as [String: Any])
        } catch {
            return jsonError(statusCode(for: error), error.localizedDescription)
        }
    }

    private func handleDelete(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }

        guard let path = request.query["path"], !path.isEmpty else {
            return jsonError(400, "Missing 'path' parameter")
        }

        do {
            try fileOps.deleteItem(path: path)
            return GCDWebServerResponse(jsonObject: [
                "success": true,
                "path": path
            ] as [String: Any])
        } catch {
            return jsonError(statusCode(for: error), error.localizedDescription)
        }
    }

    private func handleMkdir(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }

        guard let dataReq = request as? GCDWebServerDataRequest,
              let json = dataReq.jsonObject as? [String: Any],
              let path = json["path"] as? String else {
            return jsonError(400, "Missing JSON body with 'path' field")
        }

        do {
            try fileOps.createDirectory(path: path)
            return GCDWebServerResponse(jsonObject: [
                "success": true,
                "path": path
            ] as [String: Any])
        } catch {
            return jsonError(statusCode(for: error), error.localizedDescription)
        }
    }

    private func handleUpload(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }

        guard let path = request.query["path"], !path.isEmpty else {
            return jsonError(400, "Missing 'path' query parameter")
        }

        guard let body = request.body, body.count > 0 else {
            return jsonError(400, "Empty request body")
        }

        guard let resolved = pathResolver.validatePath(path) else {
            return jsonError(403, "Access denied: \(path)")
        }

        // Ensure parent directory exists
        let parent = (resolved as NSString).deletingLastPathComponent
        do {
            if !FileManager.default.fileExists(atPath: parent) {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
        } catch {
            return jsonError(500, "Failed to create parent directory: \(error.localizedDescription)")
        }

        // Write raw binary body directly to the file
        if !FileManager.default.createFile(atPath: resolved, contents: body) {
            return jsonError(500, "Write failed: \(resolved)")
        }

        return GCDWebServerResponse(jsonObject: [
            "success": true,
            "path": path,
            "size": body.count
        ] as [String: Any])
    }

    private func handleAppend(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }

        guard let path = request.query["path"], !path.isEmpty else {
            return jsonError(400, "Missing 'path' query parameter")
        }

        guard let chunk = request.body, chunk.count > 0 else {
            return jsonError(400, "Empty request body")
        }

        guard let resolved = pathResolver.validatePath(path) else {
            return jsonError(403, "Access denied: \(path)")
        }

        // Ensure parent directory exists
        let parent = (resolved as NSString).deletingLastPathComponent
        do {
            if !FileManager.default.fileExists(atPath: parent) {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
        } catch {
            return jsonError(500, "Failed to create parent directory: \(error.localizedDescription)")
        }

        // Append to file (create if doesn't exist)
        if FileManager.default.fileExists(atPath: resolved) {
            guard let handle = FileHandle(forWritingAtPath: resolved) else {
                return jsonError(500, "Cannot open file for writing: \(resolved)")
            }
            handle.seekToEndOfFile()
            handle.write(chunk)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: resolved, contents: chunk)
        }

        // Get final file size
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
        let totalSize = (attrs?[.size] as? Int64) ?? 0

        return GCDWebServerResponse(jsonObject: [
            "success": true,
            "path": path,
            "appendedBytes": chunk.count,
            "totalSize": totalSize
        ] as [String: Any])
    }

    // MARK: - Helpers

    private func checkAuth(_ request: GCDWebServerRequest) -> GCDWebServerResponse? {
        let authHeader = request.headers["Authorization"]
        if let errDict = auth.validate(authHeader: authHeader) {
            let code = errDict["code"] as? Int ?? 401
            let msg = errDict["error"] as? String ?? "Unauthorized"
            return jsonError(code, msg)
        }
        return nil
    }

    private func jsonError(_ code: Int, _ message: String) -> GCDWebServerResponse {
        let resp = GCDWebServerResponse(jsonObject: ["error": message])
        resp.statusCode = Int(code)
        return resp
    }

    private func statusCode(for error: Error) -> Int {
        guard let fileError = error as? FileError else { return 500 }
        switch fileError {
        case .pathDenied: return 403
        case .notFound: return 404
        case .isDirectory, .notDirectory: return 400
        case .readFailed, .writeFailed, .deleteFailed, .mkdirFailed: return 500
        }
    }

    static func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        return address
    }
}
