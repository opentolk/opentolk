import AppKit
import SwiftUI
import ServiceManagement

enum AppState {
    case idle
    case recording
    case transcribing
    case processing
}

final class StatusBarController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var audioRecorder: AudioRecorder!
    private var transcriber: TranscriptionProvider!
    private var state: AppState = .idle

    private var popover: NSPopover!
    private var popoverViewModel = MainPopoverViewModel()
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var upgradeWindow: NSWindow?
    private var pluginsWindow: NSWindow?
    private var eventMonitor: Any?
    private var providerObserver: Any?
    private var hotkeyObserver: Any?
    private var wakeObserver: Any?
    private var activePluginName: String?
    private let recordingOverlay = RecordingOverlayController()

    /// Known Whisper hallucination phrases produced on silence/quiet audio.
    private static let whisperHallucinations: Set<String> = [
        "thank you", "thank you.", "thanks.", "thanks",
        "thank you for watching", "thank you for watching.",
        "thanks for watching", "thanks for watching.",
        "subscribe", "subscribe.", "like and subscribe",
        "bye", "bye.", "bye bye", "bye bye.",
        "you", "you.",
        "the end", "the end.",
        "...", "..",
    ]

    private func isHallucination(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.whisperHallucinations.contains(cleaned)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupHotkey()
        setupAudioRecorder()
        setupPopover()

        transcriber = TranscriberFactory.makeProvider()

        // Observe provider changes from Settings
        providerObserver = NotificationCenter.default.addObserver(
            forName: .transcriptionProviderChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.transcriber = TranscriberFactory.makeProvider()
            self?.popoverViewModel.refresh()
        }

        // Observe hotkey changes from Settings
        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hotkeyManager.restart()
        }

        updateIcon()

        // Re-register hotkey and audio engine after system wake
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.hotkeyManager.restart()
            self.audioRecorder.resetEngine()
        }

        // Validate subscription periodically
        SubscriptionManager.shared.validateIfNeeded()

        // Initialize auth state and trigger sync
        _ = AuthManager.shared
        SyncManager.shared.syncIfNeeded()

        // Emit app launch event
        PluginEventBus.shared.emit(event: .appLaunch, data: nil)

        // Check for first launch
        if isFirstLaunch() {
            showOnboarding()
        }
    }

    // MARK: - First Launch

    private func isFirstLaunch() -> Bool {
        let key = "hasCompletedOnboarding"
        if UserDefaults.standard.bool(forKey: key) { return false }
        return true
    }

    private func markOnboardingComplete() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        try? SMAppService.mainApp.register()
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(statusBarClicked(_:))
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 280)
        popover.behavior = .transient
        popover.animates = true

        let contentView = MainPopoverView(
            viewModel: popoverViewModel,
            onStartDictation: { [weak self] in self?.handleTap() },
            onOpenHistory: { [weak self] in
                self?.popover.performClose(nil)
                self?.showHistory()
            },
            onOpenSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.showSettings()
            },
            onQuit: { [weak self] in self?.quitApp() }
        )
        popover.contentViewController = NSHostingController(rootView: contentView)
    }

    private func updateIcon() {
        DispatchQueue.main.async {
            if let button = self.statusItem.button {
                let symbolName: String
                let color: NSColor
                switch self.state {
                case .idle:
                    symbolName = "mic.fill"
                    color = .controlAccentColor
                case .recording:
                    symbolName = "record.circle.fill"
                    color = .systemRed
                case .transcribing:
                    symbolName = "hourglass"
                    color = .systemOrange
                case .processing:
                    symbolName = "gearshape.fill"
                    color = .systemPurple
                }

                if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "OpenTolk") {
                    let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                    let configured = image.withSymbolConfiguration(config)
                    button.image = configured
                    button.image?.isTemplate = self.state == .idle
                    if self.state != .idle {
                        button.contentTintColor = color
                    } else {
                        button.contentTintColor = nil
                    }
                }
                button.title = ""
            }
            self.popoverViewModel.appState = self.state
            self.popoverViewModel.activePluginName = self.activePluginName
            self.popoverViewModel.refresh()

            // Show/hide floating recording indicator
            if self.state == .idle {
                self.recordingOverlay.hide()
            } else {
                self.recordingOverlay.show(state: self.state)
            }
        }
    }

    // MARK: - Click Handling

    @objc private func statusBarClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            guard let button = statusItem.button else { return }
            popoverViewModel.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Close popover when clicking outside
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
                if let monitor = self?.eventMonitor {
                    NSEvent.removeMonitor(monitor)
                    self?.eventMonitor = nil
                }
            }
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let statusText: String
        switch state {
        case .idle: statusText = "Ready"
        case .recording: statusText = "Recording..."
        case .transcribing: statusText = "Transcribing..."
        case .processing: statusText = "Running Plugin..."
        }
        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        // Input Device submenu
        let micSubmenu = NSMenu()
        let currentMicID = Config.shared.selectedMicrophoneID

        let defaultItem = NSMenuItem(title: "System Default", action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = "" as String
        defaultItem.state = currentMicID.isEmpty ? .on : .off
        micSubmenu.addItem(defaultItem)

        let devices = AudioRecorder.availableInputDevices()
        if !devices.isEmpty {
            micSubmenu.addItem(NSMenuItem.separator())
            for device in devices {
                let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.uid
                item.state = device.uid == currentMicID ? .on : .off
                micSubmenu.addItem(item)
            }
        }

        let micMenuItem = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        micMenuItem.submenu = micSubmenu
        menu.addItem(micMenuItem)
        menu.addItem(NSMenuItem.separator())

        let historyItem = NSMenuItem(title: "History...", action: #selector(menuShowHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(menuShowSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let pluginsItem = NSMenuItem(title: "Plugins...", action: #selector(menuShowPlugins), keyEquivalent: "")
        pluginsItem.target = self
        menu.addItem(pluginsItem)

        if SubscriptionManager.shared.isPro {
            let manageItem = NSMenuItem(title: "Manage Subscription...", action: #selector(manageSubscription), keyEquivalent: "")
            manageItem.target = self
            menu.addItem(manageItem)
        } else if Config.shared.selectedProvider == .cloud {
            let upgradeItem = NSMenuItem(title: "Upgrade to Pro...", action: #selector(menuShowUpgrade), keyEquivalent: "")
            upgradeItem.target = self
            menu.addItem(upgradeItem)
        }

        menu.addItem(NSMenuItem.separator())

        let checkUpdatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit OpenTolk", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // Reset so left-click shows popover
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyManager = HotkeyManager()

        hotkeyManager.onTap = { [weak self] in
            self?.handleTap()
        }

        hotkeyManager.onHoldStart = { [weak self] in
            self?.handleHoldStart()
        }

        hotkeyManager.onHoldEnd = { [weak self] in
            self?.handleHoldEnd()
        }

        hotkeyManager.start()
    }

    // MARK: - Audio

    private func setupAudioRecorder() {
        audioRecorder = AudioRecorder()
    }

    // MARK: - Dictation Flow

    private func handleTap() {
        guard state == .idle else { return }

        // Cloud provider requires sign-in
        let provider = Config.shared.selectedProvider
        if provider == .cloud && !AuthManager.shared.isSignedIn {
            DispatchQueue.main.async { self.showSettings() }
            return
        }

        // Check usage limit only for cloud free tier
        if provider == .cloud && !SubscriptionManager.shared.isPro && UsageTracker.shared.wordsRemaining() <= 0 {
            // Re-check subscription status before blocking — it may not have loaded yet
            Task {
                await SubscriptionManager.shared.refreshStatus()
                await MainActor.run {
                    if SubscriptionManager.shared.isPro {
                        self.beginTapRecording()
                    } else {
                        self.showUpgrade()
                    }
                }
            }
            return
        }

        beginTapRecording()
    }

    private func beginTapRecording() {
        state = .recording
        updateIcon()
        SoundFeedback.playRecordingStart()

        audioRecorder.onSilenceStop = { [weak self] audio in
            DispatchQueue.main.async {
                self?.handleRecordingComplete(audio: audio)
            }
        }
        audioRecorder.recordUntilSilence()
    }

    private func handleHoldStart() {
        guard state == .idle else { return }

        // Cloud provider requires sign-in
        let provider = Config.shared.selectedProvider
        if provider == .cloud && !AuthManager.shared.isSignedIn {
            DispatchQueue.main.async { self.showSettings() }
            return
        }

        // Check usage limit only for cloud free tier
        if provider == .cloud && !SubscriptionManager.shared.isPro && UsageTracker.shared.wordsRemaining() <= 0 {
            Task {
                await SubscriptionManager.shared.refreshStatus()
                await MainActor.run {
                    if SubscriptionManager.shared.isPro {
                        self.beginHoldRecording()
                    } else {
                        self.showUpgrade()
                    }
                }
            }
            return
        }

        beginHoldRecording()
    }

    private func beginHoldRecording() {
        state = .recording
        updateIcon()
        SoundFeedback.playRecordingStart()

        audioRecorder.startRecording()
    }

    private func handleHoldEnd() {
        guard state == .recording else { return }

        let audio = audioRecorder.stopRecording()
        handleRecordingComplete(audio: audio)
    }

    private func handleRecordingComplete(audio: RecordedAudio?) {
        SoundFeedback.playRecordingStop()

        guard let audio = audio else {
            state = .idle
            updateIcon()
            return
        }

        state = .transcribing
        updateIcon()

        Task {
            do {
                let result = try await transcriber.transcribe(audio: audio)
                await MainActor.run {
                    let text = result.text
                    guard !text.isEmpty, !self.isHallucination(text) else {
                        state = .idle
                        updateIcon()
                        SoundFeedback.playError()
                        return
                    }
                    // Track word usage locally (cloud also tracks server-side)
                    let wordCount = text.split(separator: " ").count
                    UsageTracker.shared.recordWords(count: wordCount)

                    // Emit transcription event
                    PluginEventBus.shared.emit(event: .transcriptionComplete, data: text)

                    // Route: snippets first, then plugins (async), then default paste
                    if let snippet = SnippetManager.shared.match(text) {
                        HistoryManager.shared.add(text: text)
                        PasteManager.paste(snippet.body)
                        SoundFeedback.playSuccess()
                        state = .idle
                        updateIcon()
                    } else {
                        self.routeToPlugin(text: text)
                    }
                }
            } catch {
                await MainActor.run {
                    print("Transcription error: \(error.localizedDescription)")
                    SoundFeedback.playError()
                    state = .idle
                    updateIcon()
                }
            }
        }
    }

    /// Routes text through the async plugin router and handles the result.
    private func routeToPlugin(text: String) {
        Task {
            // PluginRouter.route is now async (for intent classification)
            if let match = await PluginRouter.route(text) {
                await MainActor.run {
                    self.activePluginName = match.plugin.manifest.name
                    self.state = .processing
                    self.updateIcon()
                    HistoryManager.shared.add(text: text)
                }

                do {
                    let pluginResult = try await PluginRunner.run(match: match)
                    await MainActor.run {
                        OutputHandler.deliver(pluginResult, from: match.plugin)
                        PluginEventBus.shared.emit(event: .pluginOutput, data: text)
                        SoundFeedback.playSuccess()
                        self.activePluginName = nil
                        self.state = .idle
                        self.updateIcon()
                    }
                } catch {
                    await MainActor.run {
                        print("Plugin error: \(error.localizedDescription)")
                        PasteManager.paste(text)
                        SoundFeedback.playSuccess()
                        self.activePluginName = nil
                        self.state = .idle
                        self.updateIcon()
                    }
                }
            } else {
                await MainActor.run {
                    // Default behavior: paste transcribed text
                    HistoryManager.shared.add(text: text)
                    PasteManager.paste(text)
                    SoundFeedback.playSuccess()
                    self.state = .idle
                    self.updateIcon()
                }
            }
        }
    }

    // MARK: - URL Scheme Handling

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString)
        else { return }
        handleURLEvent(url)
    }

    func handleURLEvent(_ url: URL) {
        if url.host == "install-plugin" {
            Task { @MainActor in
                PluginInstaller.handleInstallURL(url)
            }
            return
        }
        if url.host == "subscription-activated" {
            SubscriptionManager.shared.handleSubscriptionActivated()
            popoverViewModel.refresh()
            // Replace upgrade window with success view
            if let window = upgradeWindow {
                let successView = UpgradeSuccessView {
                    self.upgradeWindow?.close()
                    self.upgradeWindow = nil
                }
                window.contentViewController = NSHostingController(rootView: successView)
                window.title = "Welcome to Pro"
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        popoverViewModel.refresh()
    }

    // MARK: - Windows

    private func showHistory() {
        if let window = historyWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let historyView = HistoryView()
        let hostingController = NSHostingController(rootView: historyView)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Dictation History"
        window.contentViewController = hostingController
        window.isFloatingPanel = true
        window.level = .floating
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        showInDock()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow = window
    }

    private func showSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "OpenTolk Settings"
        window.contentViewController = hostingController
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        showInDock()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func showOnboarding() {
        let onboardingView = OnboardingView { [weak self] in
            self?.markOnboardingComplete()
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to OpenTolk"
        window.contentViewController = hostingController
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        showInDock()
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    private func showUpgrade() {
        if let window = upgradeWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let upgradeView = UpgradeView { [weak self] in
            self?.upgradeWindow?.close()
            self?.upgradeWindow = nil
        }
        let hostingController = NSHostingController(rootView: upgradeView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Upgrade to Pro"
        window.contentViewController = hostingController
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        showInDock()
        NSApp.activate(ignoringOtherApps: true)
        upgradeWindow = window
    }

    private func showPlugins() {
        if let window = pluginsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let pluginsView = PluginsView()
        let hostingController = NSHostingController(rootView: pluginsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "OpenTolk Plugins"
        window.contentViewController = hostingController
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        showInDock()
        NSApp.activate(ignoringOtherApps: true)
        pluginsWindow = window
    }

    // MARK: - Dock Icon Management

    private func showInDock() {
        NSApp.setActivationPolicy(.regular)
    }

    private func hideFromDockIfNoWindows() {
        let managedWindows: [NSWindow?] = [historyWindow, settingsWindow, onboardingWindow, upgradeWindow, pluginsWindow]
        let hasVisibleWindow = managedWindows.contains { $0?.isVisible == true }
        if !hasVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Delay slightly so the window's isVisible updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.hideFromDockIfNoWindows()
        }
    }

    // MARK: - Menu Actions

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        Config.shared.selectedMicrophoneID = uid
    }

    @objc private func menuShowHistory() { showHistory() }
    @objc private func menuShowSettings() { showSettings() }
    @objc private func menuShowPlugins() { showPlugins() }
    @objc private func menuShowUpgrade() { showUpgrade() }
    @objc private func menuQuit() { quitApp() }

    @objc private func manageSubscription() {
        guard let token = AuthTokenStore.accessToken,
              let url = URL(string: "\(Config.apiBaseURL)/manage?token=\(token)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdates() {
        UpdateManager.shared.checkForUpdates()
    }

    private func quitApp() {
        if let observer = providerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = hotkeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        hotkeyManager.stop()
        NSApp.terminate(nil)
    }
}
