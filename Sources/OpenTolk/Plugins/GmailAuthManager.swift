import AuthenticationServices
import AppKit
import Foundation
import CommonCrypto

/// Manages Gmail OAuth2 with PKCE for client-side token exchange.
/// Separate from GoogleSignInCoordinator because Gmail needs different scopes,
/// client-side token exchange, and refresh token flow for long-lived sessions.
final class GmailAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GmailAuthManager()

    // Reuse the same Google Cloud client ID
    private static let clientID = GoogleSignInCoordinator.clientID
    private static let callbackScheme = "com.googleusercontent.apps.1003102578677-7k83gsc46gcee708n68j5h8nsufuiq84"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let scopes = "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.modify email"

    // Keychain keys
    private enum Keys {
        static let accessToken = "gmail_access_token"
        static let refreshToken = "gmail_refresh_token"
        static let email = "gmail_email"
        static let tokenExpiry = "gmail_token_expiry"
    }

    /// Retained during OAuth flow to prevent deallocation.
    private var activeAuthSession: ASWebAuthenticationSession?

    private override init() { super.init() }

    // MARK: - Public API

    var isConnected: Bool {
        KeychainHelper.load(key: Keys.refreshToken) != nil
    }

    var connectedEmail: String? {
        KeychainHelper.load(key: Keys.email)
    }

    /// Runs the full OAuth flow: browser consent → token exchange → store tokens.
    func connect() async throws {
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.generateCodeChallenge(from: codeVerifier)
        let redirectUri = "\(Self.callbackScheme):/oauthredirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let authURL = components.url else {
            throw GmailAuthError.failedToBuildURL
        }

        // Present OAuth consent in browser (must run on main thread, session must be retained)
        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [self] in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: Self.callbackScheme
                ) { [self] callbackURL, error in
                    self.activeAuthSession = nil
                    if let error = error {
                        if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            continuation.resume(throwing: GmailAuthError.cancelled)
                        } else {
                            continuation.resume(throwing: GmailAuthError.oauthFailed(error.localizedDescription))
                        }
                        return
                    }
                    guard let callbackURL = callbackURL else {
                        continuation.resume(throwing: GmailAuthError.oauthFailed("No callback URL"))
                        return
                    }
                    continuation.resume(returning: callbackURL)
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.activeAuthSession = session
                session.start()
            }
        }

        // Extract auth code
        guard let urlComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GmailAuthError.oauthFailed("No code in callback URL")
        }

        // Exchange code for tokens
        try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier, redirectUri: redirectUri)

        // Fetch email address
        try await fetchAndStoreEmail()
    }

    /// Clears all stored tokens.
    func disconnect() {
        KeychainHelper.delete(key: Keys.accessToken)
        KeychainHelper.delete(key: Keys.refreshToken)
        KeychainHelper.delete(key: Keys.email)
        KeychainHelper.delete(key: Keys.tokenExpiry)
    }

    /// Returns a valid access token, refreshing if expired.
    func getAccessToken() async throws -> String {
        // Check if current token is still valid
        if let token = KeychainHelper.load(key: Keys.accessToken),
           let expiryString = KeychainHelper.load(key: Keys.tokenExpiry),
           let expiry = Double(expiryString),
           Date().timeIntervalSince1970 < expiry - 60 { // 60s buffer
            return token
        }

        // Need to refresh
        guard let refreshToken = KeychainHelper.load(key: Keys.refreshToken) else {
            throw GmailAuthError.notConnected
        }

        return try await refreshAccessToken(refreshToken: refreshToken)
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, codeVerifier: String, redirectUri: String) async throws {
        let body = [
            "client_id": Self.clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectUri,
        ]

        let tokenResponse = try await postTokenRequest(body: body)

        KeychainHelper.save(key: Keys.accessToken, value: tokenResponse.accessToken)
        if let refresh = tokenResponse.refreshToken {
            KeychainHelper.save(key: Keys.refreshToken, value: refresh)
        }
        let expiry = Date().timeIntervalSince1970 + Double(tokenResponse.expiresIn)
        KeychainHelper.save(key: Keys.tokenExpiry, value: String(expiry))
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        let body = [
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]

        let tokenResponse = try await postTokenRequest(body: body)

        KeychainHelper.save(key: Keys.accessToken, value: tokenResponse.accessToken)
        let expiry = Date().timeIntervalSince1970 + Double(tokenResponse.expiresIn)
        KeychainHelper.save(key: Keys.tokenExpiry, value: String(expiry))

        return tokenResponse.accessToken
    }

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
    }

    private func postTokenRequest(body: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw GmailAuthError.failedToBuildURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse

        guard let httpResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailAuthError.tokenExchangeFailed(errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw GmailAuthError.tokenExchangeFailed("Invalid token response")
        }

        return TokenResponse(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: expiresIn
        )
    }

    // MARK: - Email Fetch

    private func fetchAndStoreEmail() async throws {
        let token = KeychainHelper.load(key: Keys.accessToken) ?? ""
        guard let url = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let email = json["email"] as? String {
            KeychainHelper.save(key: Keys.email, value: email)
        }
    }

    // MARK: - PKCE Helpers

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .ascii) else { return "" }
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}

// MARK: - Errors

enum GmailAuthError: LocalizedError {
    case failedToBuildURL
    case cancelled
    case oauthFailed(String)
    case tokenExchangeFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .failedToBuildURL: return "Failed to build OAuth URL"
        case .cancelled: return "Sign-in was cancelled"
        case .oauthFailed(let msg): return "OAuth failed: \(msg)"
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .notConnected: return "Gmail is not connected. Please connect Gmail in plugin settings."
        }
    }
}
