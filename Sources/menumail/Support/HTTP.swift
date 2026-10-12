import Foundation

enum HTTP {
    static func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw MailError.http(status, String(decoding: data.prefix(600), as: UTF8.self))
        }
        return data
    }

    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }
}

nonisolated enum MailError: LocalizedError {
    case http(Int, String)
    case auth(String)
    case notSignedIn
    case cancelled

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            if let message = Self.googleErrorMessage(body) { return "Gmail error \(status): \(message)" }
            return "HTTP \(status): \(body)"
        case .auth(let message): return message
        case .notSignedIn: return "This account is signed out. Reconnect it in Settings."
        case .cancelled: return "Sign-in was canceled."
        }
    }

    /// Whether the account's refresh token no longer works and the user has to sign in again.
    var needsReauthentication: Bool {
        switch self {
        case .notSignedIn: true
        case .http(let status, let body): status == 400 && body.contains("invalid_grant")
        default: false
        }
    }

    /// Gmail's "slow down" responses: 429, or 403 with a rate-limit reason
    /// (https://developers.google.com/workspace/gmail/api/guides/handle-errors).
    var isRateLimit: Bool {
        guard case .http(let status, let body) = self else { return false }
        return status == 429 || (status == 403 && body.contains("ateLimitExceeded"))
    }

    private static func googleErrorMessage(_ body: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] { return error["message"] as? String }
        return object["error_description"] as? String ?? object["error"] as? String
    }
}
