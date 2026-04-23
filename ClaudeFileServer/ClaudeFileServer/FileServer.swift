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

        // POST /api/zip_extract?path=<dir> — body is application/zip, unzip into <dir>
        server.addHandler(forMethod: "POST", path: "/api/zip_extract", request: GCDWebServerRequest.self) { [weak self] request in
            self?.handleZipExtract(request: request)
        }

        // GET /api/zip_create?path=<dir> — stream a zip of <dir> back as application/zip
        server.addHandler(forMethod: "GET", path: "/api/zip_create", request: GCDWebServerRequest.self) { [weak self] request in
            self?.handleZipCreate(request: request)
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

    private func handleZipExtract(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }

        guard let destPath = request.query["path"], !destPath.isEmpty else {
            return jsonError(400, "Missing 'path' query parameter")
        }
        guard let body = request.body, body.count > 0 else {
            return jsonError(400, "Empty request body (expected application/zip)")
        }
        guard let resolvedDest = pathResolver.validatePath(destPath) else {
            return jsonError(403, "Access denied: \(destPath)")
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: resolvedDest, withIntermediateDirectories: true)
        } catch {
            return jsonError(500, "Failed to create destination: \(error.localizedDescription)")
        }

        // ZIPFoundation reads from a file URL or Data. Write the uploaded body
        // to a tmp zip, open as Archive, iterate entries, extract each under
        // resolvedDest.
        let tmpZip = (NSTemporaryDirectory() as NSString).appendingPathComponent("cfs_upload_\(UUID().uuidString).zip")
        guard fm.createFile(atPath: tmpZip, contents: body) else {
            return jsonError(500, "Failed to stage upload zip")
        }
        defer { try? fm.removeItem(atPath: tmpZip) }

        guard let archive = Archive(url: URL(fileURLWithPath: tmpZip), accessMode: .read) else {
            return jsonError(400, "Uploaded body is not a valid zip")
        }

        var filesExtracted = 0
        var bytesWritten: Int64 = 0
        let destURL = URL(fileURLWithPath: resolvedDest)
        do {
            for entry in archive {
                let entryURL = destURL.appendingPathComponent(entry.path)
                // Path-traversal guard: the final resolved path must still be
                // under destURL.
                let standardized = entryURL.standardizedFileURL.path
                guard standardized.hasPrefix(destURL.standardizedFileURL.path) else {
                    return jsonError(400, "Unsafe entry path in zip: \(entry.path)")
                }
                switch entry.type {
                case .directory:
                    try fm.createDirectory(at: entryURL, withIntermediateDirectories: true)
                case .file:
                    try fm.createDirectory(at: entryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // extract throws if the file already exists; sync workflow
                    // expects overwrite semantics.
                    if fm.fileExists(atPath: entryURL.path) {
                        try fm.removeItem(at: entryURL)
                    }
                    _ = try archive.extract(entry, to: entryURL)
                    bytesWritten += Int64(entry.uncompressedSize)
                    filesExtracted += 1
                case .symlink:
                    // Skip symlinks for safety.
                    continue
                }
            }
        } catch {
            return jsonError(500, "Zip extract failed: \(error.localizedDescription)")
        }

        return GCDWebServerResponse(jsonObject: [
            "success": true,
            "path": resolvedDest,
            "files_extracted": filesExtracted,
            "bytes_written": bytesWritten
        ] as [String: Any])
    }

    private func handleZipCreate(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }

        guard let srcPath = request.query["path"], !srcPath.isEmpty else {
            return jsonError(400, "Missing 'path' query parameter")
        }
        guard let resolvedSrc = pathResolver.validatePath(srcPath) else {
            return jsonError(403, "Access denied: \(srcPath)")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedSrc, isDirectory: &isDir), isDir.boolValue else {
            return jsonError(400, "Not a directory: \(resolvedSrc)")
        }

        // NSFileCoordinator .forUploading produces a native .zip of the
        // directory in a tmp location. Public API, no deps.
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var zipData: Data?
        var zipError: String?
        let srcURL = URL(fileURLWithPath: resolvedSrc)

        coordinator.coordinate(readingItemAt: srcURL, options: [.forUploading], error: &coordError) { (zipURL: URL) in
            do {
                zipData = try Data(contentsOf: zipURL)
            } catch {
                zipError = error.localizedDescription
            }
        }

        if let err = coordError {
            return jsonError(500, "Zip create failed: \(err.localizedDescription)")
        }
        if let err = zipError {
            return jsonError(500, "Zip read failed: \(err)")
        }
        guard let data = zipData else {
            return jsonError(500, "Zip create produced no data")
        }

        let resp = GCDWebServerDataResponse(data: data, contentType: "application/zip")
        let name = (resolvedSrc as NSString).lastPathComponent
        resp.setValue("attachment; filename=\"\(name).zip\"", forAdditionalHeader: "Content-Disposition")
        return resp
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
