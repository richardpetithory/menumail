import AppKit
import CryptoKit
import Foundation

/// A "Desktop app" OAuth client from a Google Cloud project with the Gmail API enabled.
///
/// Builds made with a `Config/oauth-client.env` carry one in Info.plist (`builtIn`), so users
/// can just sign in. Users can also bring their own (e.g. one from their Workspace org); its
/// secret goes in the Keychain. Google doesn't treat installed-app secrets as confidential.
nonisolated struct OAuthClient: Equatable, Sendable {
    var id: String
    var secret: String

    static let builtIn: OAuthClient? = {
        let info = Bundle.main.infoDictionary
        guard let id = info?["MenuMailOAuthClientID"] as? String, !id.isEmpty,
              let secret = info?["MenuMailOAuthClientSecret"] as? String, !secret.isEmpty else { return nil }
        return OAuthClient(id: id, secret: secret)
    }()

    var isBuiltIn: Bool { self == Self.builtIn }

    @MainActor static func load(id: String) -> OAuthClient? {
        if let builtIn, builtIn.id == id { return builtIn }
        return Keychain.get(SecretKey.clientSecret(clientID: id)).map { OAuthClient(id: id, secret: $0) }
    }

    @MainActor func save() {
        guard !isBuiltIn else { return }
        Keychain.set(secret, for: SecretKey.clientSecret(clientID: id))
    }
}

/// Installed-app OAuth: opens Google's consent page in the default browser and receives the
/// redirect on a temporary 127.0.0.1 listener (loopback + PKCE). MenuMail never sees passwords.
final class GoogleOAuth {
    static let scope = "https://www.googleapis.com/auth/gmail.readonly"

    let client: OAuthClient
    private var refreshToken: String?
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var activeReceiver: LoopbackReceiver?

    init(client: OAuthClient, refreshToken: String? = nil) {
        self.client = client
        self.refreshToken = refreshToken
    }

    /// Runs the browser consent flow. Afterwards `currentRefreshToken` holds the new token.
    /// `loginHint` preselects an account when reconnecting; `browser` picks the browser profile
    /// to sign in with (nil: the default browser).
    func signIn(loginHint: String? = nil, browser: BrowserProfile? = nil) async throws {
        let verifier = Self.randomURLSafeString(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafeString(byteCount: 16)

        let receiver = try LoopbackReceiver()
        activeReceiver = receiver
        defer { activeReceiver = nil }
        let port = try await receiver.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            // Always show the account chooser so a second account can be added while the
            // browser is signed in to the first, and always return a refresh token.
            .init(name: "prompt", value: "select_account consent"),
            .init(name: "state", value: state),
        ]
        if let loginHint { components.queryItems?.append(.init(name: "login_hint", value: loginHint)) }
        Browsers.open(components.url!, in: browser)

        let params = try await receiver.waitForCallback()
        if let error = params["error"] {
            throw MailError.auth(error == "access_denied" ? "Access wasn't granted in the browser." : error)
        }
        guard params["state"] == state, let code = params["code"] else {
            throw MailError.auth("Invalid OAuth callback.")
        }
        if let granted = params["scope"], !granted.contains(Self.scope) {
            throw MailError.auth("MenuMail needs permission to read your mail. Sign in again and leave the Gmail box checked.")
        }

        let token = try await tokenRequest([
            ("code", code),
            ("client_id", client.id),
            ("client_secret", client.secret),
            ("redirect_uri", redirectURI),
            ("grant_type", "authorization_code"),
            ("code_verifier", verifier),
        ])
        guard let refresh = token.refresh_token else {
            throw MailError.auth("Google did not return a refresh token.")
        }
        refreshToken = refresh
        store(token)
    }

    func cancelSignIn() {
        activeReceiver?.cancel()
    }

    var currentRefreshToken: String? { refreshToken }

    func validAccessToken() async throws -> String {
        if let accessToken, expiry > .now.addingTimeInterval(60) { return accessToken }
        guard let refreshToken else { throw MailError.notSignedIn }
        let token = try await tokenRequest([
            ("refresh_token", refreshToken),
            ("client_id", client.id),
            ("client_secret", client.secret),
            ("grant_type", "refresh_token"),
        ])
        store(token)
        return token.access_token
    }

    func invalidateAccessToken() {
        accessToken = nil
    }

    private nonisolated struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Double
        var refresh_token: String?
    }

    private func store(_ token: TokenResponse) {
        accessToken = token.access_token
        expiry = .now.addingTimeInterval(token.expires_in)
    }

    private func tokenRequest(_ fields: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.formBody(fields)
        return try JSONDecoder().decode(TokenResponse.self, from: try await HTTP.data(for: request))
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        Data((0..<byteCount).map { _ in UInt8.random(in: 0...255) }).base64URLEncoded
    }
}

extension Data {
    nonisolated var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
