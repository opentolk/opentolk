import AppKit
import AVFoundation
import UserNotifications
import SwiftUI

enum OutputHandler {

    /// Delivers a plugin run result (complete or streaming).
    @MainActor
    static func deliver(_ result: PluginRunResult, from plugin: LoadedPlugin) {
        switch result {
        case .complete(let pluginResult):
            deliverComplete(pluginResult, from: plugin)
        case .stream(let stream, let plugin):
            deliverStream(stream, from: plugin)
        }
    }

    /// Delivers a completed plugin result.
    @MainActor
    static func deliverComplete(_ result: PluginResult, from plugin: LoadedPlugin) {
        let mode = result.outputMode ?? plugin.manifest.output?.mode ?? .paste
        let text = result.text
        let format = plugin.manifest.output?.format ?? .plain

        // Primary delivery
        deliverMode(mode, text: text, pluginName: plugin.manifest.name, format: format, plugin: plugin)

        // Side-effect deliveries
        if let alsoModes = plugin.manifest.output?.also {
            for alsoMode in alsoModes {
                deliverMode(alsoMode, text: text, pluginName: plugin.manifest.name, format: format, plugin: plugin)
            }
        }
    }

    /// Delivers a streaming result — opens conversation panel.
    @MainActor
    static func deliverStream(_ stream: AsyncThrowingStream<StreamEvent, Error>, from plugin: LoadedPlugin) {
        let format = plugin.manifest.output?.format ?? .plain
        showConversationPanel(stream: stream, plugin: plugin, format: format)
    }

    // MARK: - Mode Dispatch

    @MainActor
    private static func deliverMode(_ mode: OutputMode, text: String, pluginName: String, format: OutputFormat, plugin: LoadedPlugin) {
        switch mode {
        case .paste:
            PasteManager.paste(text)
        case .clipboard:
            copyToClipboard(text)
        case .notify:
            showNotification(title: pluginName, body: text)
        case .speak:
            speak(text)
        case .panel:
            showPanel(text: text, pluginName: pluginName)
        case .store:
            HistoryManager.shared.add(text: text)
        case .silent:
            break
        case .reply:
            showConversationPanel(initialText: text, plugin: plugin, format: format)
        }
    }

    // MARK: - Clipboard

    private static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Notification

    private static func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Speak

    private static func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        speechSynth.speak(utterance)
    }

    private static let speechSynth = AVSpeechSynthesizer()

    // MARK: - Panel (simple result view)

    @MainActor
    private static func showPanel(text: String, pluginName: String) {
        let view = PluginResultView(text: text, pluginName: pluginName)
        let hostingController = NSHostingController(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = pluginName
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        panelWindows.append(panel)
        panel.delegate = PanelDelegate.shared
    }

    // MARK: - Conversation Panel (streaming + multi-turn)

    @MainActor
    private static func showConversationPanel(stream: AsyncThrowingStream<StreamEvent, Error>? = nil,
                                               initialText: String? = nil,
                                               plugin: LoadedPlugin,
                                               format: OutputFormat) {
        let viewModel = ConversationPanelViewModel(plugin: plugin, format: format)

        if let stream {
            viewModel.startStreaming(stream)
        } else if let initialText {
            viewModel.addAssistantMessage(initialText)
        }

        let view = ConversationPanelView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: view)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = plugin.manifest.name
        panel.contentViewController = hostingController
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        panelWindows.append(panel)
        panel.delegate = PanelDelegate.shared
    }

    /// Tracks open panel windows to prevent deallocation.
    private static var panelWindows: [NSPanel] = []

    static func removePanel(_ panel: NSPanel) {
        panelWindows.removeAll { $0 === panel }
    }
}

// MARK: - Panel Delegate

private class PanelDelegate: NSObject, NSWindowDelegate {
    static let shared = PanelDelegate()

    func windowWillClose(_ notification: Notification) {
        if let panel = notification.object as? NSPanel {
            OutputHandler.removePanel(panel)
        }
    }
}
