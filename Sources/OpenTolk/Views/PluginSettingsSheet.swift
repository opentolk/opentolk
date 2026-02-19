import SwiftUI

struct PluginSettingsSheet: View {
    let plugin: LoadedPlugin
    let onDismiss: () -> Void

    @State private var values: [String: String] = [:]
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.manifest.name)
                        .font(.headline)
                    Text("Plugin Settings")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Settings form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if plugin.manifest.permissions?.contains(.gmail) == true {
                        GmailConnectSection()
                        Divider()
                    }

                    if let settings = plugin.manifest.settings {
                        ForEach(settings, id: \.key) { setting in
                            settingField(for: setting)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
            .padding()
        }
        .frame(width: 400, height: 350)
        .onAppear { loadValues() }
    }

    // MARK: - Setting Fields

    @ViewBuilder
    private func settingField(for setting: PluginSetting) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(setting.label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if setting.required == true {
                    Text("*")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            switch setting.type {
            case .string:
                TextField(
                    setting.placeholder ?? "",
                    text: binding(for: setting.key)
                )
                .textFieldStyle(.roundedBorder)

            case .secret:
                SecureField(
                    setting.placeholder ?? "Enter value...",
                    text: binding(for: setting.key)
                )
                .textFieldStyle(.roundedBorder)

            case .select:
                Picker("", selection: binding(for: setting.key)) {
                    if let options = setting.options {
                        ForEach(options, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                }
                .labelsHidden()

            case .bool:
                Toggle(isOn: boolBinding(for: setting.key)) {
                    EmptyView()
                }
                .labelsHidden()

            case .text:
                TextEditor(text: binding(for: setting.key))
                    .frame(height: 80)
                    .border(Color.secondary.opacity(0.3))

            case .number:
                TextField(
                    setting.placeholder ?? "0",
                    text: binding(for: setting.key)
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Bindings

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    private func boolBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { values[key] == "true" },
            set: { values[key] = $0 ? "true" : "false" }
        )
    }

    // MARK: - Load / Save

    private func loadValues() {
        values = PluginManager.shared.resolvedSettings(for: plugin)
    }

    private func save() {
        isSaving = true
        PluginManager.shared.saveSettings(values, for: plugin.manifest.id, manifest: plugin.manifest)
        isSaving = false
    }
}
