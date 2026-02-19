import SwiftUI

struct PermissionApprovalView: View {
    let plugin: LoadedPlugin
    let permissions: [PluginPermission]
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 36))
                    .foregroundColor(.orange)

                Text("Permission Request")
                    .font(.headline)

                Text("\"\(plugin.manifest.name)\" requires the following permissions:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()

            Divider()

            // Permissions list
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(permissions, id: \.rawValue) { permission in
                        HStack(spacing: 12) {
                            Image(systemName: iconForPermission(permission))
                                .foregroundColor(.accentColor)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(permission.rawValue.capitalized)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(PluginPermissionManager.descriptions[permission] ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Actions
            HStack {
                Button("Deny") { onDeny() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow") { onApprove() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 360, height: 320)
    }

    private func iconForPermission(_ permission: PluginPermission) -> String {
        switch permission {
        case .network: return "globe"
        case .filesystem: return "folder"
        case .clipboard: return "doc.on.clipboard"
        case .notifications: return "bell"
        case .ai: return "brain"
        case .microphone: return "mic"
        case .gmail: return "envelope"
        }
    }
}
