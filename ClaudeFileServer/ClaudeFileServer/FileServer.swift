import CryptoKit
import Foundation
import UIKit

final class FileServer: ObservableObject {
    @Published var isRunning = false
    @Published var port: UInt = 8080
    @Published var ipAddress: String = "unknown"

    let auth: AuthMiddleware
    private var server: GCDWebServer?
    private var bonjourService: NetService?
    private let fileOps = FileOperations.shared
    private let pathResolver = PathResolver.shared
    // Serial queue to serialize /api/append writes across concurrent
    // GCDWebServer handler dispatches so FileHandle open→seek→write→close
    // can't interleave and corrupt the file.
    private let appendQueue = DispatchQueue(label: "com.claudecode.fileserver.append")

    init() {
        self.auth = AuthMiddleware()
        self.ipAddress = Self.getWiFiAddress() ?? "unknown"
    }

    func start() {
        guard !isRunning else { return }

        let webServer = GCDWebServer()
        server = webServer

        registerRoutes(on: webServer)

        // The vendored GCDWebServer subset accepts a bonjourName arg but
        // doesn't publish — we run our own NetService below.
        let started = webServer.start(withPort: port, bonjourName: nil)
        isRunning = started && webServer.isRunning
        ipAddress = Self.getWiFiAddress() ?? "unknown"

        if isRunning {
            publishBonjour()
        }
    }

    func stop() {
        bonjourService?.stop()
        bonjourService = nil
        server?.stop()
        server = nil
        isRunning = false
    }

    private func publishBonjour() {
        let service = NetService(domain: "local.",
                                 type: "_claude-file-server._tcp.",
                                 name: UIDevice.current.name,
                                 port: Int32(port))
        // TXT record advertises the service version so the client can
        // tell builds apart during discovery.
        let txt: [String: Data] = [
            "version": Data("1.0".utf8),
            "path": Data("/api".utf8),
        ]
        let txtData = NetService.data(fromTXTRecord: txt)
        service.setTXTRecord(txtData)
        service.publish()
        bonjourService = service
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

        // GET /api/stat?path=... — cheap metadata probe, no file content
        server.addHandler(forMethod: "GET", path: "/api/stat", request: GCDWebServerRequest.self) { [weak self] request in
            self?.handleStat(request: request)
        }

        // GET /api/sha256?path=... — server-side hash, tiny response
        server.addHandler(forMethod: "GET", path: "/api/sha256", request: GCDWebServerRequest.self) { [weak self] request in
            self?.handleSha256(request: request)
        }

        // GET /api/read_range?path=...&offset=N&length=M — raw bytes, no JSON wrapping
        server.addHandler(forMethod: "GET", path: "/api/read_range", request: GCDWebServerRequest.self) { [weak self] request in
            self?.handleReadRange(request: request)
        }

        // POST /api/edit — {path, old_string, new_string, count?} server-side string replace
        server.addHandler(forMethod: "POST", path: "/api/edit", request: GCDWebServerDataRequest.self) { [weak self] request in
            self?.handleEdit(request: request)
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
            return jsonError(403, "Access denied")
        }

        // Ensure parent directory exists
        let parent = (resolved as NSString).deletingLastPathComponent
        do {
            if !FileManager.default.fileExists(atPath: parent) {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
        } catch {
            return jsonError(500, "Failed to create parent directory")
        }

        if !FileManager.default.createFile(atPath: resolved, contents: body) {
            return jsonError(500, "Write failed")
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
            return jsonError(403, "Access denied")
        }

        // Ensure parent directory exists
        let parent = (resolved as NSString).deletingLastPathComponent
        do {
            if !FileManager.default.fileExists(atPath: parent) {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
        } catch {
            return jsonError(500, "Failed to create parent directory")
        }

        // Serialize append ops per-server so concurrent requests can't
        // interleave seek/write on the same file.
        var totalSize: Int64 = 0
        var failure: (Int, String)? = nil
        appendQueue.sync {
            if FileManager.default.fileExists(atPath: resolved) {
                guard let handle = FileHandle(forWritingAtPath: resolved) else {
                    failure = (500, "Cannot open file for writing")
                    return
                }
                handle.seekToEndOfFile()
                handle.write(chunk)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: resolved, contents: chunk)
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
            totalSize = (attrs?[.size] as? Int64) ?? 0
        }
        if let (code, msg) = failure { return jsonError(code, msg) }

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
            return jsonError(403, "Access denied")
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: resolvedDest, withIntermediateDirectories: true)
        } catch {
            return jsonError(500, "Failed to create destination")
        }

        // ZIPFoundation reads from a file URL or Data. Write the uploaded body
        // to a tmp zip, open as Archive, iterate entries, extract each under
        // resolvedDest.
        let tmpZip = (NSTemporaryDirectory() as NSString).appendingPathComponent("cfs_upload_\(UUID().uuidString).zip")
        guard fm.createFile(atPath: tmpZip, contents: body) else {
            return jsonError(500, "Failed to stage upload zip")
        }
        defer { try? fm.removeItem(atPath: tmpZip) }

        let archive: Archive
        do {
            archive = try Archive(url: URL(fileURLWithPath: tmpZip), accessMode: .read)
        } catch {
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
            return jsonError(500, "Zip extract failed")
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
            return jsonError(403, "Access denied")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedSrc, isDirectory: &isDir), isDir.boolValue else {
            return jsonError(400, "Not a directory")
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
            return jsonError(500, "Zip create failed")
        }
        if zipError != nil {
            return jsonError(500, "Zip read failed")
        }
        guard let data = zipData else {
            return jsonError(500, "Zip create produced no data")
        }

        let resp = GCDWebServerResponse(data: data, contentType: "application/zip")
        let name = (resolvedSrc as NSString).lastPathComponent
        resp.setValue("attachment; filename=\"\(name).zip\"", forAdditionalHeader: "Content-Disposition")
        return resp
    }

    private func handleStat(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }
        guard let path = request.query["path"], !path.isEmpty else {
            return jsonError(400, "Missing 'path' parameter")
        }
        guard let resolved = pathResolver.validatePath(path) else {
            return jsonError(403, "Access denied")
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: resolved, isDirectory: &isDir)
        if !exists {
            return GCDWebServerResponse(jsonObject: [
                "path": resolved, "exists": false,
            ] as [String: Any])
        }
        let attrs = try? fm.attributesOfItem(atPath: resolved)
        let size = (attrs?[.size] as? Int64) ?? 0
        let modified = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
        let perms = (attrs?[.posixPermissions] as? Int) ?? 0
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return GCDWebServerResponse(jsonObject: [
            "path": resolved,
            "exists": true,
            "isDirectory": isDir.boolValue,
            "size": isDir.boolValue ? 0 : size,
            "modified": fmt.string(from: modified),
            "permissions": String(format: "%o", perms),
        ] as [String: Any])
    }

    private func handleSha256(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }
        guard let path = request.query["path"], !path.isEmpty else {
            return jsonError(400, "Missing 'path' parameter")
        }
        guard let resolved = pathResolver.validatePath(path) else {
            return jsonError(403, "Access denied")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            return jsonError(404, "Not found")
        }
        if isDir.boolValue {
            return jsonError(400, "Is a directory")
        }
        // Stream-hash 64 KB at a time so we don't allocate the whole file.
        guard let handle = FileHandle(forReadingAtPath: resolved) else {
            return jsonError(500, "Read failed")
        }
        defer { handle.closeFile() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return GCDWebServerResponse(jsonObject: [
            "path": resolved,
            "size": total,
            "sha256": hex,
        ] as [String: Any])
    }

    private func handleReadRange(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }
        guard let path = request.query["path"], !path.isEmpty else {
            return jsonError(400, "Missing 'path' parameter")
        }
        guard let resolved = pathResolver.validatePath(path) else {
            return jsonError(403, "Access denied")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            return jsonError(404, "Not found")
        }
        if isDir.boolValue {
            return jsonError(400, "Is a directory")
        }
        let offset = Int64(request.query["offset"] ?? "0") ?? 0
        let length = Int(request.query["length"] ?? "65536") ?? 65536
        guard offset >= 0, length > 0, length <= 16 * 1024 * 1024 else {
            return jsonError(400, "offset must be >=0, length in 1..16MB")
        }
        guard let handle = FileHandle(forReadingAtPath: resolved) else {
            return jsonError(500, "Read failed")
        }
        defer { handle.closeFile() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
        let fileSize = (attrs?[.size] as? Int64) ?? 0
        if offset >= fileSize {
            // Empty range — return 0 bytes rather than erroring, so tail-reads
            // of small files just come back empty.
            let resp = GCDWebServerResponse(data: Data(), contentType: "application/octet-stream")
            resp.setValue("\(fileSize)", forAdditionalHeader: "X-File-Size")
            resp.setValue("\(offset)", forAdditionalHeader: "X-Range-Offset")
            resp.setValue("0", forAdditionalHeader: "X-Range-Length")
            return resp
        }
        handle.seek(toFileOffset: UInt64(offset))
        let data = handle.readData(ofLength: length)
        let resp = GCDWebServerResponse(data: data, contentType: "application/octet-stream")
        resp.setValue("\(fileSize)", forAdditionalHeader: "X-File-Size")
        resp.setValue("\(offset)", forAdditionalHeader: "X-Range-Offset")
        resp.setValue("\(data.count)", forAdditionalHeader: "X-Range-Length")
        return resp
    }

    private func handleEdit(request: GCDWebServerRequest) -> GCDWebServerResponse? {
        if let err = checkAuth(request) { return err }
        guard let dataReq = request as? GCDWebServerDataRequest,
              let json = dataReq.jsonObject as? [String: Any],
              let path = json["path"] as? String,
              let oldStr = json["old_string"] as? String,
              let newStr = json["new_string"] as? String else {
            return jsonError(400, "Body must be {path, old_string, new_string, count?}")
        }
        if oldStr.isEmpty {
            return jsonError(400, "old_string must not be empty")
        }
        let expected = (json["count"] as? Int) ?? 1  // 0 = replace all
        guard let resolved = pathResolver.validatePath(path) else {
            return jsonError(403, "Access denied")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir) else {
            return jsonError(404, "Not found")
        }
        if isDir.boolValue {
            return jsonError(400, "Is a directory")
        }
        guard let data = FileManager.default.contents(atPath: resolved),
              let text = String(data: data, encoding: .utf8) else {
            return jsonError(400, "File is not UTF-8 text")
        }
        // Count occurrences first so we can distinguish 0 vs >1.
        var occurrences = 0
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: oldStr, range: searchRange) {
            occurrences += 1
            searchRange = found.upperBound..<text.endIndex
        }
        if occurrences == 0 {
            return jsonError(404, "old_string not found")
        }
        if expected > 0 && occurrences != expected {
            return jsonError(409, "old_string occurs \(occurrences) times, expected \(expected)")
        }
        let replaced: String
        if expected == 0 {
            replaced = text.replacingOccurrences(of: oldStr, with: newStr)
        } else {
            // Replace exactly `expected` occurrences starting from the top.
            var working = text
            for _ in 0..<expected {
                if let r = working.range(of: oldStr) {
                    working.replaceSubrange(r, with: newStr)
                }
            }
            replaced = working
        }
        guard let outData = replaced.data(using: .utf8) else {
            return jsonError(500, "UTF-8 encode failed")
        }
        if !FileManager.default.createFile(atPath: resolved, contents: outData) {
            return jsonError(500, "Write failed")
        }
        return GCDWebServerResponse(jsonObject: [
            "success": true,
            "path": resolved,
            "replacements": expected > 0 ? expected : occurrences,
            "new_size": outData.count,
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
