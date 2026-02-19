import SwiftUI

// MARK: - View Model

@MainActor
final class ConversationPanelViewModel: ObservableObject {
    let plugin: LoadedPlugin
    let format: OutputFormat

    @Published var messages: [ConversationMessage] = []
    @Published var isStreaming = false
    @Published var inputText = ""

    struct ConversationMessage: Identifiable {
        let id = UUID()
        let role: String   // "user" or "assistant"
        var text: String
        var isStreaming: Bool = false
    }

    init(plugin: LoadedPlugin, format: OutputFormat) {
        self.plugin = plugin
        self.format = format
    }

    // MARK: - Add completed assistant message

    func addAssistantMessage(_ text: String) {
        messages.append(ConversationMessage(role: "assistant", text: text))
        // Track in conversation manager
        ConversationManager.shared.append(
            message: ChatMessage(role: "assistant", content: text),
            for: plugin.manifest.id
        )
    }

    // MARK: - Streaming

    func startStreaming(_ stream: AsyncThrowingStream<StreamEvent, Error>) {
        isStreaming = true
        let messageIndex = messages.count
        messages.append(ConversationMessage(role: "assistant", text: "", isStreaming: true))

        Task {
            var fullText = ""
            do {
                for try await event in stream {
                    switch event {
                    case .textDelta(let delta):
                        fullText += delta
                        messages[messageIndex].text = fullText
                    case .done(let text):
                        fullText = text
                        messages[messageIndex].text = fullText
                        messages[messageIndex].isStreaming = false
                    }
                }
            } catch {
                if fullText.isEmpty {
                    messages[messageIndex].text = "Error: \(error.localizedDescription)"
                }
                messages[messageIndex].isStreaming = false
            }

            isStreaming = false

            // Track in conversation manager
            ConversationManager.shared.append(
                message: ChatMessage(role: "assistant", content: fullText),
                for: plugin.manifest.id
            )
        }
    }

    // MARK: - Send Follow-up

    func sendFollowUp() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        messages.append(ConversationMessage(role: "user", text: text))

        // Track user message
        ConversationManager.shared.append(
            message: ChatMessage(role: "user", content: text),
            for: plugin.manifest.id
        )

        // Create synthetic match with the follow-up text
        let syntheticMatch = PluginMatch(
            plugin: plugin,
            trigger: plugin.manifest.trigger,
            triggerWord: "",
            input: text,
            rawInput: text
        )

        Task {
            do {
                let result = try await PluginRunner.run(match: syntheticMatch)
                switch result {
                case .complete(let pluginResult):
                    addAssistantMessage(pluginResult.text)
                case .stream(let stream, _):
                    startStreaming(stream)
                }
            } catch {
                messages.append(ConversationMessage(role: "assistant", text: "Error: \(error.localizedDescription)"))
            }
        }
    }
}

// MARK: - Conversation Panel View

struct ConversationPanelView: View {
    @ObservedObject var viewModel: ConversationPanelViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundColor(.accentColor)
                Text(viewModel.plugin.manifest.name)
                    .font(.headline)
                Spacer()
                Button(action: clearConversation) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Clear conversation")
            }
            .padding()

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(
                                message: message,
                                format: viewModel.format
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input area
            HStack(spacing: 8) {
                TextField("Type a follow-up...", text: $viewModel.inputText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .onSubmit { viewModel.sendFollowUp() }
                    .disabled(viewModel.isStreaming)

                Button(action: { viewModel.sendFollowUp() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isStreaming || viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 380, minHeight: 400)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isInputFocused = true
            }
        }
    }

    private func clearConversation() {
        ConversationManager.shared.clear(for: viewModel.plugin.manifest.id)
        viewModel.messages.removeAll()
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ConversationPanelViewModel.ConversationMessage
    let format: OutputFormat

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == "user" {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                // Message content
                Group {
                    if format == .markdown, message.role == "assistant" {
                        Text(markdownAttributedString(message.text))
                            .textSelection(.enabled)
                    } else {
                        Text(message.text)
                            .textSelection(.enabled)
                    }
                }
                .font(.body)
                .padding(10)
                .background(message.role == "user" ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                .cornerRadius(12)

                // Actions for assistant messages
                if message.role == "assistant" && !message.isStreaming {
                    HStack(spacing: 12) {
                        Button(action: { copyText(message.text) }) {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)

                        Button(action: { PasteManager.paste(message.text) }) {
                            Label("Paste", systemImage: "doc.on.clipboard")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    .foregroundColor(.secondary)
                }

                // Streaming indicator
                if message.isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if message.role == "assistant" {
                Spacer(minLength: 60)
            }
        }
    }

    private func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func markdownAttributedString(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
