import AppKit
import Foundation

/// Executes tools called by AI plugins during conversation.
enum PluginToolRunner {

    struct ToolCall {
        let name: String
        let arguments: [String: Any]
    }

    struct ToolResult {
        let name: String
        let content: String
    }

    /// Runs a tool and returns the result text.
    static func run(tool: ToolConfig, call: ToolCall, plugin: LoadedPlugin) async throws -> ToolResult {
        switch tool.type {
        case .builtin:
            return try await runBuiltin(tool: tool, call: call, plugin: plugin)
        case .script:
            return try await runScript(tool: tool, call: call, plugin: plugin)
        }
    }

    // MARK: - Builtin Tools

    private static func runBuiltin(tool: ToolConfig, call: ToolCall, plugin: LoadedPlugin) async throws -> ToolResult {
        switch call.name {
        case "web_search":
            let query = call.arguments["query"] as? String ?? ""
            let result = try await webSearch(query: query)
            return ToolResult(name: call.name, content: result)

        case "read_clipboard":
            let content = await MainActor.run {
                NSPasteboard.general.string(forType: .string) ?? ""
            }
            return ToolResult(name: call.name, content: content)

        case "paste":
            let text = call.arguments["text"] as? String ?? ""
            await MainActor.run { PasteManager.paste(text) }
            return ToolResult(name: call.name, content: "Pasted successfully")

        case "run_plugin":
            let pluginID = tool.config?["plugin_id"] ?? call.arguments["plugin_id"] as? String ?? ""
            let input = call.arguments["input"] as? String ?? ""
            let result = try await runPlugin(pluginID: pluginID, input: input)
            return ToolResult(name: call.name, content: result)

        case "gmail_check":
            return try await runGmailCheck(call: call)

        case "gmail_read":
            return try await runGmailRead(call: call)

        case "gmail_reply":
            return try await runGmailReply(call: call)

        case "gmail_send":
            return try await runGmailSend(call: call)

        case "gmail_archive":
            return try await runGmailArchive(call: call)

        default:
            return ToolResult(name: call.name, content: "Unknown builtin tool: \(call.name)")
        }
    }

    // MARK: - Gmail Tools

    private static func runGmailCheck(call: ToolCall) async throws -> ToolResult {
        guard await GmailAuthManager.shared.isConnected else {
            return ToolResult(name: call.name, content: "Error: Gmail is not connected. Please connect Gmail in plugin settings first.")
        }

        let query = call.arguments["query"] as? String
        let maxResults = call.arguments["max_results"] as? Int ?? 10

        do {
            let messages = try await GmailAPIClient.listMessages(query: query, maxResults: maxResults)
            if messages.isEmpty {
                return ToolResult(name: call.name, content: "No emails found.")
            }

            var result = "Found \(messages.count) email(s):\n\n"
            for (i, msg) in messages.enumerated() {
                let unreadTag = msg.isUnread ? " [UNREAD]" : ""
                result += "\(i + 1). **\(msg.subject)**\(unreadTag)\n"
                result += "   From: \(msg.from)\n"
                result += "   Date: \(msg.date)\n"
                result += "   Preview: \(msg.snippet)\n"
                result += "   ID: \(msg.id)\n\n"
            }
            return ToolResult(name: call.name, content: result)
        } catch {
            return ToolResult(name: call.name, content: "Error checking email: \(error.localizedDescription)")
        }
    }

    private static func runGmailRead(call: ToolCall) async throws -> ToolResult {
        guard await GmailAuthManager.shared.isConnected else {
            return ToolResult(name: call.name, content: "Error: Gmail is not connected. Please connect Gmail in plugin settings first.")
        }

        guard let messageId = call.arguments["message_id"] as? String, !messageId.isEmpty else {
            return ToolResult(name: call.name, content: "Error: message_id is required.")
        }

        do {
            let message = try await GmailAPIClient.getMessage(id: messageId)
            var result = "**\(message.subject)**\n"
            result += "From: \(message.from)\n"
            result += "To: \(message.to)\n"
            result += "Date: \(message.date)\n\n"
            result += message.body
            return ToolResult(name: call.name, content: result)
        } catch {
            return ToolResult(name: call.name, content: "Error reading email: \(error.localizedDescription)")
        }
    }

    private static func runGmailReply(call: ToolCall) async throws -> ToolResult {
        guard await GmailAuthManager.shared.isConnected else {
            return ToolResult(name: call.name, content: "Error: Gmail is not connected. Please connect Gmail in plugin settings first.")
        }

        guard let messageId = call.arguments["message_id"] as? String, !messageId.isEmpty else {
            return ToolResult(name: call.name, content: "Error: message_id is required.")
        }
        guard let body = call.arguments["body"] as? String, !body.isEmpty else {
            return ToolResult(name: call.name, content: "Error: body is required.")
        }

        do {
            let sentId = try await GmailAPIClient.replyToMessage(messageId: messageId, body: body)
            return ToolResult(name: call.name, content: "Reply sent successfully (ID: \(sentId)).")
        } catch {
            return ToolResult(name: call.name, content: "Error sending reply: \(error.localizedDescription)")
        }
    }

    private static func runGmailSend(call: ToolCall) async throws -> ToolResult {
        guard await GmailAuthManager.shared.isConnected else {
            return ToolResult(name: call.name, content: "Error: Gmail is not connected. Please connect Gmail in plugin settings first.")
        }

        guard let to = call.arguments["to"] as? String, !to.isEmpty else {
            return ToolResult(name: call.name, content: "Error: to is required.")
        }
        guard let subject = call.arguments["subject"] as? String, !subject.isEmpty else {
            return ToolResult(name: call.name, content: "Error: subject is required.")
        }
        guard let body = call.arguments["body"] as? String, !body.isEmpty else {
            return ToolResult(name: call.name, content: "Error: body is required.")
        }

        do {
            let sentId = try await GmailAPIClient.sendMessage(to: to, subject: subject, body: body)
            return ToolResult(name: call.name, content: "Email sent successfully to \(to) (ID: \(sentId)).")
        } catch {
            return ToolResult(name: call.name, content: "Error sending email: \(error.localizedDescription)")
        }
    }

    private static func runGmailArchive(call: ToolCall) async throws -> ToolResult {
        guard await GmailAuthManager.shared.isConnected else {
            return ToolResult(name: call.name, content: "Error: Gmail is not connected. Please connect Gmail in plugin settings first.")
        }

        guard let messageId = call.arguments["message_id"] as? String, !messageId.isEmpty else {
            return ToolResult(name: call.name, content: "Error: message_id is required.")
        }

        do {
            try await GmailAPIClient.archiveMessage(id: messageId)
            return ToolResult(name: call.name, content: "Email archived successfully.")
        } catch {
            return ToolResult(name: call.name, content: "Error archiving email: \(error.localizedDescription)")
        }
    }

    // MARK: - Script Tools

    private static func runScript(tool: ToolConfig, call: ToolCall, plugin: LoadedPlugin) async throws -> ToolResult {
        guard let command = tool.command else {
            return ToolResult(name: call.name, content: "Error: Script tool missing command")
        }

        let scriptPath = plugin.directoryURL.appendingPathComponent(command).path
        let timeout: TimeInterval = 30

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            process.currentDirectoryURL = plugin.directoryURL
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Pass arguments as JSON on stdin
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            if let argsData = try? JSONSerialization.data(withJSONObject: call.arguments) {
                stdinPipe.fileHandleForWriting.write(argsData)
            }
            stdinPipe.fileHandleForWriting.closeFile()

            var env = ProcessInfo.processInfo.environment
            env["OPENTOLK_TOOL_NAME"] = call.name
            if let argsJSON = try? JSONSerialization.data(withJSONObject: call.arguments),
               let argsString = String(data: argsJSON, encoding: .utf8) {
                env["OPENTOLK_TOOL_ARGS"] = argsString
            }
            // Pass plugin settings as environment variables
            let settings = PluginManager.shared.resolvedSettings(for: plugin)
            for (key, value) in settings {
                env["OPENTOLK_SETTINGS_\(key.uppercased())"] = value
            }
            process.environment = env

            let timeoutItem = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            process.terminationHandler = { proc in
                timeoutItem.cancel()
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus != 0 {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    continuation.resume(returning: ToolResult(name: call.name, content: "Error: \(stderr)"))
                    return
                }

                continuation.resume(returning: ToolResult(name: call.name, content: stdout))
            }

            do {
                try process.run()
            } catch {
                timeoutItem.cancel()
                continuation.resume(returning: ToolResult(name: call.name, content: "Error: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Helpers

    private static func webSearch(query: String) async throws -> String {
        // Simple web search using DuckDuckGo instant answer API
        guard !query.isEmpty else { return "No query provided" }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1") else {
            return "Invalid search query"
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "No results found"
        }

        var results: [String] = []
        if let abstract = json["Abstract"] as? String, !abstract.isEmpty {
            results.append(abstract)
        }
        if let relatedTopics = json["RelatedTopics"] as? [[String: Any]] {
            for topic in relatedTopics.prefix(3) {
                if let text = topic["Text"] as? String {
                    results.append(text)
                }
            }
        }

        return results.isEmpty ? "No results found for: \(query)" : results.joined(separator: "\n\n")
    }

    private static func runPlugin(pluginID: String, input: String) async throws -> String {
        guard let plugin = PluginManager.shared.enabledPlugins.first(where: { $0.manifest.id == pluginID }) else {
            return "Plugin not found: \(pluginID)"
        }

        let syntheticMatch = PluginMatch(
            plugin: plugin,
            trigger: plugin.manifest.trigger,
            triggerWord: "",
            input: input,
            rawInput: input
        )

        let result = try await PluginRunner.run(match: syntheticMatch)
        switch result {
        case .complete(let pluginResult):
            return pluginResult.text
        case .stream(let stream, _):
            var collected = ""
            for try await event in stream {
                if case .textDelta(let delta) = event {
                    collected += delta
                }
            }
            return collected
        }
    }
}
