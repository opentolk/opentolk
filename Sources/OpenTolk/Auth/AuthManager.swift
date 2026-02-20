import Foundation
import AppKit

struct AuthUser: Codable {
    let id: String
    let email: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
    }
}

struct AuthTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let userId: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case userId = "user_id"
    }
}

final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    private static let baseURL = Config.apiBaseURL

    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var user: AuthUser?

    private let appleCoordinator = AppleSignInCoordinator()
    private let googleCoordinator = GoogleSignInCoordinator()
    private var isRefreshing = false
    private var refreshWaiters: [CheckedContinuation<Void, Error>] = []

    private init() {
        loadCachedState()
    }

    // MARK: - Cached State

    private func loadCachedState() {
        if let savedUser = AuthTokenStore.savedUser,
           AuthTokenStore.accessToken != nil || AuthTokenStore.refreshToken != nil {
            user = savedUser
            isSignedIn = true
        }
    }

    // MARK: - Sign In with Apple

    /// Called from SignInWithAppleButton's onCompletion with the token already extracted.
    func signInWithAppleToken(identityToken: String, displayName: String?) async throws {
        let body: [String: Any] = [
            "identity_token": identityToken,
            "display_name": displayName as Any,
        ]

        let tokens = try await postAuth(endpoint: "/auth/apple", body: body)
        await storeTokensAndFetchUser(tokens)
    }

    // MARK: - Sign In with Google

    func signInWithGoogle() async throws {
        let result = try await googleCoordinator.signIn()

        let body: [String: Any] = [
            "code": result.code,
            "code_verifier": result.codeVerifier,
            "redirect_uri": result.redirectUri,
        ]

        let tokens = try await postAuth(endpoint: "/auth/google", body: body)
        await storeTokensAndFetchUser(tokens)
    }

    // MARK: - Magic Code

    func sendMagicCode(email: String) async throws {
        let body: [String: Any] = ["email": email]

        guard let url = URL(string: "\(Self.baseURL)/auth/magic-link/send") else {
            throw AuthError.magicLinkFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.magicLinkFailed("Invalid response")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.magicLinkFailed(errorBody)
        }
    }

    func verifyMagicCode(email: String, code: String) async throws {
        let body: [String: Any] = ["email": email, "code": code]
        let tokens = try await postAuth(endpoint: "/auth/magic-link/verify", body: body)
        await storeTokensAndFetchUser(tokens)
    }

    // MARK: - Authenticated Requests

    /// Attach Bearer token to a request. Auto-refreshes if token is missing.
    func attachAuth(to request: URLRequest) async throws -> URLRequest {
        var request = request
        guard let accessToken = AuthTokenStore.accessToken else {
            throw AuthError.noRefreshToken
        }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Make an authenticated request with auto-refresh on 401.
    func authenticatedRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var authedRequest = try await attachAuth(to: request)

        let (data, response) = try await URLSession.shared.data(for: authedRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.serverError("Invalid response")
        }

        if httpResponse.statusCode == 401 {
            try await refreshAccessToken()
            authedRequest = try await attachAuth(to: request)
            let (retryData, retryResponse) = try await URLSession.shared.data(for: authedRequest)
            guard let retryHttp = retryResponse as? HTTPURLResponse else {
                throw AuthError.serverError("Invalid response")
            }
            return (retryData, retryHttp)
        }

        return (data, httpResponse)
    }

    // MARK: - Token Refresh

    /// Ensure the access token is fresh, refreshing if needed. Returns the valid token.
    func ensureFreshToken() async throws -> String {
        // Make a lightweight check — try to refresh proactively
        try await refreshAccessToken()
        guard let token = AuthTokenStore.accessToken else {
            throw AuthError.noRefreshToken
        }
        return token
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken = AuthTokenStore.refreshToken else {
            await signOutLocally()
            throw AuthError.noRefreshToken
        }

        // Coalesce concurrent refresh attempts
        if isRefreshing {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                refreshWaiters.append(continuation)
            }
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
            let waiters = refreshWaiters
            refreshWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }

        let body: [String: Any] = ["refresh_token": refreshToken]
        guard let url = URL(string: "\(Self.baseURL)/auth/refresh") else {
            throw AuthError.serverError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.serverError("Invalid response")
        }

        if httpResponse.statusCode != 200 {
            // If the token in Keychain changed, another refresh already succeeded — use those tokens.
            if let currentRefresh = AuthTokenStore.refreshToken, currentRefresh != refreshToken {
                return
            }
            await signOutLocally()
            throw AuthError.serverError("Session expired. Please sign in again.")
        }
        let tokens = try JSONDecoder().decode(AuthTokenResponse.self, from: data)
        AuthTokenStore.accessToken = tokens.accessToken
        AuthTokenStore.refreshToken = tokens.refreshToken
    }

    // MARK: - Sign Out

    func signOut() async {
        // Revoke server-side
        if let refreshToken = AuthTokenStore.refreshToken {
            let body: [String: Any] = ["refresh_token": refreshToken]
            if let url = URL(string: "\(Self.baseURL)/auth/logout") {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                _ = try? await URLSession.shared.data(for: request)
            }
        }

        await signOutLocally()
        await MainActor.run {
            SubscriptionManager.shared.clearOnSignOut()
        }
    }

    @MainActor
    private func signOutLocally() {
        AuthTokenStore.clear()
        isSignedIn = false
        user = nil
    }

    // MARK: - Private Helpers

    private func postAuth(endpoint: String, body: [String: Any]) async throws -> AuthTokenResponse {
        guard let url = URL(string: "\(Self.baseURL)\(endpoint)") else {
            throw AuthError.serverError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.serverError("Invalid response")
        }

        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.serverError(errorBody)
        }

        return try JSONDecoder().decode(AuthTokenResponse.self, from: data)
    }

    @MainActor
    private func storeTokensAndFetchUser(_ tokens: AuthTokenResponse) {
        AuthTokenStore.accessToken = tokens.accessToken
        AuthTokenStore.refreshToken = tokens.refreshToken

        let tempUser = AuthUser(id: tokens.userId, email: nil, displayName: nil)
        AuthTokenStore.savedUser = tempUser
        user = tempUser
        isSignedIn = true

        // Fetch full user profile and subscription status in the background
        Task {
            await fetchAndUpdateUser()
            await SubscriptionManager.shared.refreshStatus()
        }
    }

    private func fetchAndUpdateUser() async {
        guard let url = URL(string: "\(Self.baseURL)/auth/me") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, _) = try await authenticatedRequest(request)
            let meResponse = try JSONDecoder().decode(MeResponse.self, from: data)
            await MainActor.run {
                let fetchedUser = AuthUser(
                    id: meResponse.user.id,
                    email: meResponse.user.email,
                    displayName: meResponse.user.displayName
                )
                self.user = fetchedUser
                AuthTokenStore.savedUser = fetchedUser
            }
        } catch {
            // Non-critical — we already have the userId
        }
    }
}

// MARK: - Me Response

private struct MeResponse: Codable {
    let user: MeUser
    let subscription: MeSubscription
}

private struct MeUser: Codable {
    let id: String
    let email: String?
    let displayName: String?
    let hasApple: Bool?
    let hasGoogle: Bool?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case hasApple = "has_apple"
        case hasGoogle = "has_google"
        case createdAt = "created_at"
    }
}

private struct MeSubscription: Codable {
    let plan: String?
    let status: String?
    let isPro: Bool
    let currentPeriodEnd: String?

    enum CodingKeys: String, CodingKey {
        case plan, status
        case isPro = "is_pro"
        case currentPeriodEnd = "current_period_end"
    }
}
