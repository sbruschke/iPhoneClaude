import Foundation

final class AuthMiddleware {
    private var token: String

    init(token: String? = nil) {
        self.token = token ?? AuthMiddleware.generateToken()
    }

    var currentToken: String { token }

    func regenerateToken() {
        token = AuthMiddleware.generateToken()
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
