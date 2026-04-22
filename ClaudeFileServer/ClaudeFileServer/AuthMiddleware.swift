import Foundation

final class AuthMiddleware {
    private static let tokenKey = "ClaudeFileServer.authToken"
    private var token: String

    init() {
        if let saved = UserDefaults.standard.string(forKey: AuthMiddleware.tokenKey), !saved.isEmpty {
            self.token = saved
        } else {
            let newToken = AuthMiddleware.generateToken()
            UserDefaults.standard.set(newToken, forKey: AuthMiddleware.tokenKey)
            self.token = newToken
        }
    }

    var currentToken: String { token }

    func regenerateToken() {
        token = AuthMiddleware.generateToken()
        UserDefaults.standard.set(token, forKey: AuthMiddleware.tokenKey)
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

    private func errorResponse(code: Int, message: String) -> [String: Any] {
        return ["error": message, "code": code]
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
