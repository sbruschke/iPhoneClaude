import Foundation

final class AuthMiddleware {
    private static let tokenFileName = ".claude_fileserver_token"
    private var token: String

    init() {
        if let saved = AuthMiddleware.readPersistedToken() {
            self.token = saved
        } else {
            let newToken = AuthMiddleware.generateToken()
            AuthMiddleware.persistToken(newToken)
            self.token = newToken
        }
    }

    var currentToken: String { token }

    func regenerateToken() {
        token = AuthMiddleware.generateToken()
        AuthMiddleware.persistToken(token)
    }

    /// Validates the Authorization header. Returns nil if valid, or an error response dict if invalid.
    func validate(authHeader: String?) -> [String: Any]? {
        guard let header = authHeader else {
            return errorResponse(code: 401, message: "Missing Authorization header")
        }

        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else {
            return errorResponse(code: 401, message: "Invalid Authorization format. Use: Bearer <token>")
        }

        let provided = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        guard provided == token else {
            return errorResponse(code: 403, message: "Invalid token")
        }

        return nil // Authorized
    }

    // MARK: - Persistent token storage in LC shared container root

    /// The LC container root is shared across all guest app reinstalls.
    /// Store the token file there so it survives app updates.
    private static func tokenFilePath() -> String? {
        let home = NSHomeDirectory()
        // In LC, home is like .../Data/Application/<UUID>
        // The parent (.../Data/Application/) is the shared container root
        let containerRoot = (home as NSString).deletingLastPathComponent
        guard containerRoot != "/", FileManager.default.fileExists(atPath: containerRoot) else {
            return nil
        }
        return (containerRoot as NSString).appendingPathComponent(tokenFileName)
    }

    private static func readPersistedToken() -> String? {
        // Try shared container root first
        if let path = tokenFilePath(),
           let data = FileManager.default.contents(atPath: path),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        // Fall back to UserDefaults (for non-LC environments)
        if let saved = UserDefaults.standard.string(forKey: "ClaudeFileServer.authToken"), !saved.isEmpty {
            return saved
        }
        return nil
    }

    private static func persistToken(_ token: String) {
        // Write to shared container root
        if let path = tokenFilePath() {
            try? token.write(toFile: path, atomically: true, encoding: .utf8)
        }
        // Also save to UserDefaults as fallback
        UserDefaults.standard.set(token, forKey: "ClaudeFileServer.authToken")
    }

    private func errorResponse(code: Int, message: String) -> [String: Any] {
        return ["error": message, "code": code]
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
