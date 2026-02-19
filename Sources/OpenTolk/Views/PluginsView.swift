import SwiftUI

struct PluginsView: View {
    @State private var selectedTab = 0
    @State private var plugins: [LoadedPlugin] = []
    @State private var selectedPlugin: LoadedPlugin?
    @State private var showingSettings = false
    @State private var pendingEnablePlugin: LoadedPlugin?

    var body: some View {
        VStack(spacing: 0) {
            // Tab selector
            Picker("", selection: $selectedTab) {
                Text("Installed").tag(0)
                Text("Browse").tag(1)
                Text("Updates").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // Tab content
            switch selectedTab {
            case 0:
                installedTab
            case 1:
                PluginBrowseView()
            case 2:
                updatesTab
            default:
                EmptyView()
            }
        }
        .frame(minWidth: 460, minHeight: 350)
        .onAppear { reload() }
    }

    // MARK: - Installed Tab

    private var installedTab: some View {
        VStack(spacing: 0) {
            if plugins.isEmpty {
                emptyState
            } else {
                pluginsList
            }
            Divider()
            bottomBar
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Plugins Installed")
                .font(.headline)
            Text("Browse the plugin directory or add .tolkplugin files to ~/.opentolk/plugins/")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Browse Plugins") { selectedTab = 1 }
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var pluginsList: some View {
        List {
            ForEach(plugins, id: \.manifest.id) { plugin in
                PluginRow(
                    plugin: plugin,
                    onToggle: { enabled in
                        if enabled {
                            // Check permissions before enabling
                            let unapproved = PluginPermissionManager.shared.unapprovedPermissions(for: plugin)
                            if !unapproved.isEmpty {
                                pendingEnablePlugin = plugin
                            } else {
                                PluginManager.shared.setEnabled(true, for: plugin.manifest.id)
                                reload()
                            }
                        } else {
                            PluginManager.shared.setEnabled(false, for: plugin.manifest.id)
                            reload()
                        }
                    },
                    onConfigure: {
                        selectedPlugin = plugin
                        showingSettings = true
                    },
                    onUninstall: {
                        PluginManager.shared.uninstall(pluginID: plugin.manifest.id)
                        reload()
                    }
                )
            }
        }
        .sheet(isPresented: $showingSettings) {
            if let plugin = selectedPlugin {
                PluginSettingsSheet(plugin: plugin) {
                    showingSettings = false
                }
            }
        }
        .sheet(item: $pendingEnablePlugin) { plugin in
            PermissionApprovalView(
                plugin: plugin,
                permissions: PluginPermissionManager.shared.unapprovedPermissions(for: plugin),
                onApprove: {
                    PluginPermissionManager.shared.approveAll(for: plugin)
                    PluginManager.shared.setEnabled(true, for: plugin.manifest.id)
                    pendingEnablePlugin = nil
                    reload()
                },
                onDeny: {
                    pendingEnablePlugin = nil
                    reload()
                }
            )
        }
    }

    // MARK: - Updates Tab

    private var updatesTab: some View {
        PluginUpdatesView()
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Button(action: openPluginsFolder) {
                Label("Open Plugins Folder", systemImage: "folder")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button(action: {
                PluginManager.shared.reloadPlugins()
                reload()
            }) {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
    }

    // MARK: - Actions

    private func reload() {
        plugins = PluginManager.shared.plugins
    }

    private func openPluginsFolder() {
        NSWorkspace.shared.open(PluginManager.shared.pluginsDirectoryURL)
    }
}

// MARK: - Plugin Row

private struct PluginRow: View {
    let plugin: LoadedPlugin
    let onToggle: (Bool) -> Void
    let onConfigure: () -> Void
    let onUninstall: () -> Void

    @State private var isEnabled: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pluginIcon)
                .font(.title2)
                .foregroundColor(isEnabled ? .accentColor : .secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plugin.manifest.name)
                        .font(.headline)
                    Text("v\(plugin.manifest.version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if executionTypeBadge != nil {
                        Text(executionTypeBadge!)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                Text(plugin.manifest.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if let triggers = triggerSummary {
                    Text(triggers)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }

            Spacer()

            if hasConfigurableContent {
                Button(action: onConfigure) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .help("Configure")
            }

            Button(action: onUninstall) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red.opacity(0.7))
            .help("Uninstall")

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: isEnabled) { _, newValue in
                    onToggle(newValue)
                }
        }
        .padding(.vertical, 4)
        .onAppear { isEnabled = plugin.isEnabled }
    }

    private var hasConfigurableContent: Bool {
        let hasSettings = plugin.manifest.settings != nil && !(plugin.manifest.settings!.isEmpty)
        let hasGmail = plugin.manifest.permissions?.contains(.gmail) == true
        return hasSettings || hasGmail
    }

    private var pluginIcon: String {
        switch plugin.manifest.execution {
        case .ai: return "brain"
        case .script: return "terminal"
        case .http: return "network"
        case .shortcut: return "command"
        case .pipeline: return "arrow.triangle.branch"
        }
    }

    private var executionTypeBadge: String? {
        switch plugin.manifest.execution {
        case .ai: return "AI"
        case .pipeline: return "Pipeline"
        default: return nil
        }
    }

    private var triggerSummary: String? {
        switch plugin.manifest.trigger {
        case .keyword(let config):
            return "Triggers: \(config.keywords.joined(separator: ", "))"
        case .regex(let config):
            return "Pattern: \(config.pattern)"
        case .intent(let config):
            return "Intent: \(config.intents.joined(separator: ", "))"
        case .catchAll:
            return "Trigger: catch-all"
        }
    }
}

// MARK: - Updates View

private struct PluginUpdatesView: View {
    @State private var updates: [PluginUpdateInfo] = []
    @State private var isLoading = false
    @State private var updatingIDs: Set<String> = []

    var body: some View {
        VStack {
            if isLoading {
                Spacer()
                ProgressView("Checking for updates...")
                Spacer()
            } else if updates.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                    Text("All plugins are up to date")
                        .font(.headline)
                }
                Spacer()
            } else {
                List {
                    ForEach(updates, id: \.id) { update in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(update.id)
                                    .font(.headline)
                                Text("New version: \(update.latestVersion)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if updatingIDs.contains(update.id) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button("Update") { updatePlugin(update) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { checkUpdates() }
    }

    private func checkUpdates() {
        isLoading = true
        let installed = PluginManager.shared.plugins.map { ($0.manifest.id, $0.manifest.version) }
        Task {
            do {
                let result = try await PluginRegistryClient.shared.checkUpdates(installed: installed.map { (id: $0.0, version: $0.1) })
                await MainActor.run {
                    updates = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    private func updatePlugin(_ update: PluginUpdateInfo) {
        guard let url = URL(string: update.url) else { return }
        updatingIDs.insert(update.id)
        Task {
            do {
                _ = try await PluginInstaller.install(from: url)
                await MainActor.run {
                    updatingIDs.remove(update.id)
                    checkUpdates()
                }
            } catch {
                _ = await MainActor.run {
                    updatingIDs.remove(update.id)
                }
            }
        }
    }
}

// MARK: - Plugins Tab (for SettingsView)

struct PluginsTab: View {
    var body: some View {
        VStack(spacing: 0) {
            PluginAIConfigSection()
            Divider()
            PluginsView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Plugin AI Configuration

private struct PluginAIConfigSection: View {
    @State private var selectedProvider: String = Config.shared.aiProvider
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var saved = false

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: $selectedProvider) {
                Text("OpenAI").tag("openai")
                Text("Claude").tag("anthropic")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            .onChange(of: selectedProvider) { _, newValue in
                Config.shared.aiProvider = newValue
                loadKey()
            }

            if showKey {
                TextField(keyPlaceholder, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            } else {
                SecureField(keyPlaceholder, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                showKey.toggle()
            } label: {
                Image(systemName: showKey ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)

            Button(saved ? "Saved!" : "Save") {
                Config.shared.aiAPIKey = apiKey.isEmpty ? nil : apiKey
                saved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
            }
            .controlSize(.small)
            .foregroundColor(saved ? .green : nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { loadKey() }
    }

    private var keyPlaceholder: String {
        selectedProvider == "anthropic" ? "sk-ant-..." : "sk-..."
    }

    private func loadKey() {
        apiKey = Config.shared.aiAPIKey ?? ""
    }
}
