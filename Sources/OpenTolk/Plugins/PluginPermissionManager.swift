import Foundation

final class PluginPermissionManager {
    static let shared = PluginPermissionManager()

    private let storageKey = "pluginApprovedPermissions"

    private init() {}

    // MARK: - Permission Descriptions

    static let descriptions: [PluginPermission: String] = [
        .network: "Make internet requests",
        .filesystem: "Read and write files in its data directory",
        .clipboard: "Read your clipboard contents",
        .notifications: "Send system notifications",
        .ai: "Use AI models to process your text",
        .microphone: "Access the microphone",
        .gmail: "Read and send emails through your connected Gmail account",
    ]

    // MARK: - Check Permissions

    func approvedPermissions(for pluginID: String) -> Set<PluginPermission> {
        let stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
        guard let permStrings = stored[pluginID] else { return [] }
        return Set(permStrings.compactMap { PluginPermission(rawValue: $0) })
    }

    func unapprovedPermissions(for plugin: LoadedPlugin) -> [PluginPermission] {
        let declared = Set(plugin.manifest.permissions ?? [])
        let approved = approvedPermissions(for: plugin.manifest.id)
        return Array(declared.subtracting(approved)).sorted { $0.rawValue < $1.rawValue }
    }

    func allPermissionsApproved(for plugin: LoadedPlugin) -> Bool {
        unapprovedPermissions(for: plugin).isEmpty
    }

    // MARK: - Approve / Revoke

    func approveAll(for plugin: LoadedPlugin) {
        let permissions = plugin.manifest.permissions ?? []
        var stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
        stored[plugin.manifest.id] = permissions.map { $0.rawValue }
        UserDefaults.standard.set(stored, forKey: storageKey)
    }

    func revokeAll(for pluginID: String) {
        var stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
        stored.removeValue(forKey: pluginID)
        UserDefaults.standard.set(stored, forKey: storageKey)
    }

    func hasPermission(_ permission: PluginPermission, for pluginID: String) -> Bool {
        approvedPermissions(for: pluginID).contains(permission)
    }
}
