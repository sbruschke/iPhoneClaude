import Foundation

enum FileError: Error, LocalizedError {
    case pathDenied(String)
    case notFound(String)
    case readFailed(String)
    case writeFailed(String)
    case deleteFailed(String)
    case mkdirFailed(String)
    case isDirectory(String)
    case notDirectory(String)

    var errorDescription: String? {
        switch self {
        case .pathDenied(let p): return "Access denied: \(p)"
        case .notFound(let p): return "Not found: \(p)"
        case .readFailed(let p): return "Read failed: \(p)"
        case .writeFailed(let p): return "Write failed: \(p)"
        case .deleteFailed(let p): return "Delete failed: \(p)"
        case .mkdirFailed(let p): return "Mkdir failed: \(p)"
        case .isDirectory(let p): return "Is a directory: \(p)"
        case .notDirectory(let p): return "Not a directory: \(p)"
        }
    }
}

struct FileEntry: Codable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: String
    let permissions: String
}

struct FileContent: Codable {
    let path: String
    let encoding: String
    let content: String
    let size: Int64
}

final class FileOperations {
    static let shared = FileOperations()
    private let fm = FileManager.default
    private let resolver = PathResolver.shared
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private init() {}

    func listDirectory(path: String) throws -> [FileEntry] {
        guard let resolved = resolver.validatePath(path) else {
            throw FileError.pathDenied(path)
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            if fm.fileExists(atPath: resolved) {
                throw FileError.notDirectory(resolved)
            }
            throw FileError.notFound(resolved)
        }

        let contents = try fm.contentsOfDirectory(atPath: resolved)
        return contents.compactMap { name in
            let fullPath = (resolved as NSString).appendingPathComponent(name)
            return fileEntry(name: name, path: fullPath)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func readFile(path: String) throws -> FileContent {
        guard let resolved = resolver.validatePath(path) else {
            throw FileError.pathDenied(path)
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDir) else {
            throw FileError.notFound(resolved)
        }
        if isDir.boolValue {
            throw FileError.isDirectory(resolved)
        }

        guard let data = fm.contents(atPath: resolved) else {
            throw FileError.readFailed(resolved)
        }

        let attrs = try fm.attributesOfItem(atPath: resolved)
        let size = (attrs[.size] as? Int64) ?? Int64(data.count)

        // Try UTF-8 first, fall back to base64
        if let text = String(data: data, encoding: .utf8),
           text.utf8.count == data.count || !containsNullBytes(data) {
            return FileContent(path: resolved, encoding: "utf-8", content: text, size: size)
        } else {
            return FileContent(path: resolved, encoding: "base64", content: data.base64EncodedString(), size: size)
        }
    }

    func writeFile(path: String, content: String, encoding: String = "utf-8") throws {
        guard let resolved = resolver.validatePath(path) else {
            throw FileError.pathDenied(path)
        }

        let data: Data
        if encoding == "base64" {
            guard let decoded = Data(base64Encoded: content) else {
                throw FileError.writeFailed("Invalid base64 content")
            }
            data = decoded
        } else {
            guard let encoded = content.data(using: .utf8) else {
                throw FileError.writeFailed("Failed to encode as UTF-8")
            }
            data = encoded
        }

        // Ensure parent directory exists
        let parent = (resolved as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }

        if !fm.createFile(atPath: resolved, contents: data) {
            throw FileError.writeFailed(resolved)
        }
    }

    func deleteItem(path: String) throws {
        guard let resolved = resolver.validatePath(path) else {
            throw FileError.pathDenied(path)
        }

        guard fm.fileExists(atPath: resolved) else {
            throw FileError.notFound(resolved)
        }

        do {
            try fm.removeItem(atPath: resolved)
        } catch {
            throw FileError.deleteFailed("\(resolved): \(error.localizedDescription)")
        }
    }

    func createDirectory(path: String) throws {
        guard let resolved = resolver.validatePath(path) else {
            throw FileError.pathDenied(path)
        }

        do {
            try fm.createDirectory(atPath: resolved, withIntermediateDirectories: true)
        } catch {
            throw FileError.mkdirFailed("\(resolved): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func fileEntry(name: String, path: String) -> FileEntry? {
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        let type = attrs[.type] as? FileAttributeType
        let isDir = type == .typeDirectory
        let size = (attrs[.size] as? Int64) ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? Date.distantPast
        let posix = (attrs[.posixPermissions] as? Int) ?? 0

        return FileEntry(
            name: name,
            path: path,
            isDirectory: isDir,
            size: isDir ? 0 : size,
            modified: dateFormatter.string(from: modified),
            permissions: String(format: "%o", posix)
        )
    }

    private func containsNullBytes(_ data: Data) -> Bool {
        return data.contains(0)
    }
}
