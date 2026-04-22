import Foundation

struct ResolvedPath {
    let label: String
    let path: String
    let exists: Bool
}

final class PathResolver {
    static let shared = PathResolver()

    private init() {}

    /// Discovers accessible paths within the LiveContainer shared sandbox.
    func discoverPaths() -> [ResolvedPath] {
        var paths: [ResolvedPath] = []

        // App's own Documents
        if let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
            paths.append(ResolvedPath(label: "Documents", path: docs, exists: FileManager.default.fileExists(atPath: docs)))
        }

        // App container root
        let homeDir = NSHomeDirectory()
        paths.append(ResolvedPath(label: "App Container", path: homeDir, exists: true))

        // LiveContainer shared container — in private mode, all LC guest apps live
        // under the same sandbox, so we can traverse the container root.
        // The container root is typically 3 levels up from Documents.
        let containerRoot = (homeDir as NSString).deletingLastPathComponent
        if containerRoot != "/" {
            paths.append(ResolvedPath(label: "Container Root", path: containerRoot, exists: FileManager.default.fileExists(atPath: containerRoot)))
        }

        // LiveContainer shared Documents directory (shared mode)
        // In LC shared mode, apps share a common Documents folder.
        let sharedDocs = (containerRoot as NSString).appendingPathComponent("Documents/SharedDocuments")
        if FileManager.default.fileExists(atPath: sharedDocs) {
            paths.append(ResolvedPath(label: "LC Shared Documents", path: sharedDocs, exists: true))
        }

        // LiveContainer app group containers
        let lcGroupBase = (containerRoot as NSString).appendingPathComponent("AppGroup")
        if FileManager.default.fileExists(atPath: lcGroupBase) {
            paths.append(ResolvedPath(label: "LC App Groups", path: lcGroupBase, exists: true))
        }

        // tmp directory
        let tmp = NSTemporaryDirectory()
        paths.append(ResolvedPath(label: "Temp", path: tmp, exists: FileManager.default.fileExists(atPath: tmp)))

        return paths
    }

    /// Validates that a path is within accessible boundaries (sandbox).
    /// Returns the canonicalized path if valid, nil otherwise.
    func validatePath(_ path: String) -> String? {
        let fm = FileManager.default
        // Resolve symlinks and relative components
        let resolved = (path as NSString).standardizingPath

        // Must be an absolute path
        guard resolved.hasPrefix("/") else { return nil }

        // Must be within our sandbox — check that it starts with the container root
        let homeDir = NSHomeDirectory()
        let containerRoot = (homeDir as NSString).deletingLastPathComponent

        if resolved.hasPrefix(containerRoot) || resolved.hasPrefix(NSTemporaryDirectory()) {
            return resolved
        }

        // Also allow /var/mobile paths if we can actually access them
        // (LiveContainer may map these)
        if resolved.hasPrefix("/var/mobile") || resolved.hasPrefix("/private/var/mobile") {
            // Check if we can actually stat the path or its parent
            let parentPath = (resolved as NSString).deletingLastPathComponent
            if fm.fileExists(atPath: resolved) || fm.fileExists(atPath: parentPath) {
                return resolved
            }
        }

        return nil
    }
}
