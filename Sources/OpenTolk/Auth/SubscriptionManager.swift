import Foundation
import AppKit

final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    private static let baseURL = Config.apiBaseURL
    private static let keychainProStatusKey = "subscription_pro_status"
    private static let keychainPlanKey = "subscription_plan"
    private static let keychainLastValidatedKey = "subscription_last_validated"
    private static let keychainPeriodEndKey = "subscription_period_end"
    private static let gracePeriodDays = 7

    @Published private(set) var isPro: Bool = false
    @Published private(set) var plan: String?
    @Published private(set) var status: String?
    @Published private(set) var currentPeriodEnd: Date?

    private init() {
        loadCachedStatus()
    }

    // MARK: - Public API

    func refreshStatus() async {
        guard AuthManager.shared.isSignedIn else { return }

        guard let url = URL(string: "\(Self.baseURL)/subscription/status") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await AuthManager.shared.authenticatedRequest(request)
            guard response.statusCode == 200 else { return }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let isPro = json["is_pro"] as? Bool ?? false
            let plan = json["plan"] as? String
            let status = json["status"] as? String
            let periodEndStr = json["current_period_end"] as? String
            let periodEnd: Date? = periodEndStr.flatMap { ISO8601DateFormatter().date(from: $0) }

            await MainActor.run {
                self.isPro = isPro
                self.plan = plan
                self.status = status
                self.currentPeriodEnd = periodEnd
                self.cacheStatus(isPro: isPro, plan: plan, periodEnd: periodEnd)
            }
        } catch {
            // Non-critical — use cached status
            print("Subscription status refresh failed: \(error.localizedDescription)")
        }
    }

    func validateIfNeeded() {
        guard AuthManager.shared.isSignedIn else { return }

        // Check if we need to revalidate (every 24 hours)
        if let lastStr = KeychainHelper.load(key: Self.keychainLastValidatedKey),
           let lastDate = ISO8601DateFormatter().date(from: lastStr) {
            let hoursSinceValidation = Date().timeIntervalSince(lastDate) / 3600
            if hoursSinceValidation < 24 { return }
        }

        Task {
            await refreshStatus()
        }
    }

    func openCheckout(plan: String = "annual") {
        guard AuthManager.shared.isSignedIn else { return }
        Task {
            do {
                let token = try await AuthManager.shared.ensureFreshToken()
                guard let url = URL(string: "\(Self.baseURL)/checkout?plan=\(plan)&token=\(token)") else { return }
                await MainActor.run {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                print("Failed to refresh token for checkout: \(error.localizedDescription)")
            }
        }
    }

    func handleSubscriptionActivated() {
        Task {
            await refreshStatus()
        }
    }

    func clearOnSignOut() {
        isPro = false
        plan = nil
        status = nil
        currentPeriodEnd = nil
        KeychainHelper.delete(key: Self.keychainProStatusKey)
        KeychainHelper.delete(key: Self.keychainPlanKey)
        KeychainHelper.delete(key: Self.keychainLastValidatedKey)
        KeychainHelper.delete(key: Self.keychainPeriodEndKey)
    }

    // MARK: - Private

    private func loadCachedStatus() {
        if let statusStr = KeychainHelper.load(key: Self.keychainProStatusKey),
           statusStr == "true" {
            isPro = true
            plan = KeychainHelper.load(key: Self.keychainPlanKey)

            if let endStr = KeychainHelper.load(key: Self.keychainPeriodEndKey) {
                currentPeriodEnd = ISO8601DateFormatter().date(from: endStr)
            }

            // Check grace period for offline
            if let lastStr = KeychainHelper.load(key: Self.keychainLastValidatedKey),
               let lastDate = ISO8601DateFormatter().date(from: lastStr) {
                let daysSinceValidation = Date().timeIntervalSince(lastDate) / 86400
                if daysSinceValidation > Double(Self.gracePeriodDays) {
                    isPro = false
                }
            }
        }
    }

    private func cacheStatus(isPro: Bool, plan: String?, periodEnd: Date?) {
        KeychainHelper.save(key: Self.keychainProStatusKey, value: isPro ? "true" : "false")
        KeychainHelper.save(
            key: Self.keychainLastValidatedKey,
            value: ISO8601DateFormatter().string(from: Date())
        )

        if let plan = plan {
            KeychainHelper.save(key: Self.keychainPlanKey, value: plan)
        } else {
            KeychainHelper.delete(key: Self.keychainPlanKey)
        }

        if let end = periodEnd {
            KeychainHelper.save(key: Self.keychainPeriodEndKey, value: ISO8601DateFormatter().string(from: end))
        } else {
            KeychainHelper.delete(key: Self.keychainPeriodEndKey)
        }
    }

    private func showNotification(success: Bool) {
        let alert = NSAlert()
        if success {
            alert.messageText = "Pro Activated!"
            alert.informativeText = "OpenTolk Pro has been activated. Enjoy unlimited dictation!"
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Subscription Error"
            alert.informativeText = "Could not verify your subscription. Please try again."
            alert.alertStyle = .warning
        }
        alert.runModal()
    }
}
