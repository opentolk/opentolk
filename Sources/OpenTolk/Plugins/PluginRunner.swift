import Foundation

// MARK: - Plugin Run Result

enum PluginRunResult {
    case complete(PluginResult)
    case stream(AsyncThrowingStream<StreamEvent, Error>, plugin: LoadedPlugin)
}

// MARK: - Errors

enum PluginRunnerError: LocalizedError {
    case timeout
    case scriptFailed(code: Int32, stderr: String)
    case httpError(statusCode: Int, body: String)
    case missingURL
    case missingCommand
    case missingShortcutName
    case missingSystemPrompt
    case invalidResponse
    case pipelinePluginNotFound(String)
    case permissionDenied(PluginPermission)

    var errorDescription: String? {
        switch self {
        case .timeout: return "Plugin timed out"
        case .scriptFailed(let code, let stderr): return "Script exited with code \(code): \(stderr)"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .missingURL: return "HTTP plugin missing URL"
        case .missingCommand: return "Script plugin missing command"
        case .missingShortcutName: return "Shortcut plugin missing shortcut name"
        case .missingSystemPrompt: return "AI plugin missing system prompt"
        case .invalidResponse: return "Invalid plugin response"
        case .pipelinePluginNotFound(let id): return "Pipeline plugin not found: \(id)"
        case .permissionDenied(let perm): return "Permission denied: \(perm.rawValue)"
        }
    }
}

// MARK: - Plugin Runner

enum PluginRunner {

    static func run(match: PluginMatch, conversationHistory: [ChatMessage]? = nil) async throws -> PluginRunResult {
        let settings = PluginManager.shared.resolvedSettings(for: match.plugin)

        switch match.plugin.manifest.execution {
        case .script(let config):
            return .complete(try await runScript(match: match, config: config, settings: settings))
        case .http(let config):
            return .complete(try await runHTTP(match: match, config: config, settings: settings))
        case .shortcut(let config):
            return .complete(try await runShortcut(match: match, config: config, settings: settings))
        case .ai(let config):
            return try await runAI(match: match, config: config, settings: settings, history: conversationHistory)
        case .pipeline(let config):
            return .complete(try await runPipeline(match: match, config: config, settings: settings))
        }
    }

    // MARK: - AI Execution

    private static func runAI(match: PluginMatch, config: AIConfig, settings: [String: String],
                              history: [ChatMessage]?) async throws -> PluginRunResult {
        guard let aiClient = AIClientFactory.makeClient() else {
            throw AIProviderError.noAPIKey
        }

        // Resolve system prompt
        let systemPrompt: String
        if let promptFile = config.systemPromptFile {
            let promptURL = match.plugin.directoryURL.appendingPathComponent(promptFile)
            let rawPrompt = try String(contentsOf: promptURL, encoding: .utf8)
            systemPrompt = resolveTemplate(rawPrompt, input: match.input, settings: settings)
        } else if let prompt = config.systemPrompt {
            systemPrompt = resolveTemplate(prompt, input: match.input, settings: settings)
        } else {
            throw PluginRunnerError.missingSystemPrompt
        }

        // Check if this plugin has tools
        let hasTools = config.tools != nil && !(config.tools!.isEmpty)

        // If tools are declared, use the tool-call loop (non-streaming)
        if hasTools {
            return try await runAIWithTools(
                match: match, config: config, settings: settings,
                systemPrompt: systemPrompt, history: history, aiClient: aiClient
            )
        }

        // No tools — use simple chat or streaming
        var messages: [ChatMessage] = [ChatMessage(role: "system", content: systemPrompt)]

        if config.conversational == true {
            let existingHistory = ConversationManager.shared.messages(for: match.plugin.manifest.id)
            messages.append(contentsOf: existingHistory)
        } else if let history {
            messages.append(contentsOf: history)
        }

        let userMessage = ChatMessage(role: "user", content: match.input)
        messages.append(userMessage)

        if config.conversational == true {
            ConversationManager.shared.append(message: userMessage, for: match.plugin.manifest.id)
        }

        let shouldStream = config.streaming ?? (config.conversational == true)

        if shouldStream {
            let stream = aiClient.chatStream(
                messages: messages,
                model: config.model,
                temperature: config.temperature,
                maxTokens: config.maxTokens
            )
            return .stream(stream, plugin: match.plugin)
        } else {
            let response = try await aiClient.chat(
                messages: messages,
                model: config.model,
                temperature: config.temperature,
                maxTokens: config.maxTokens
            )

            if config.conversational == true {
                ConversationManager.shared.append(
                    message: ChatMessage(role: "assistant", content: response),
                    for: match.plugin.manifest.id
                )
            }

            let mode = match.plugin.manifest.output?.mode ?? .paste
            return .complete(PluginResult(text: response, outputMode: mode))
        }
    }

    // MARK: - AI with Tool-Call Loop

    private static func runAIWithTools(
        match: PluginMatch, config: AIConfig, settings: [String: String],
        systemPrompt: String, history: [ChatMessage]?, aiClient: AIProviderClient
    ) async throws -> PluginRunResult {
        let maxToolRounds = 10  // safety limit

        // Build tool definitions for the API
        let toolDefs = buildToolDefinitions(from: config.tools ?? [])

        // Build AIMessage array
        var messages: [AIMessage] = [AIMessage(role: .system, content: systemPrompt, toolCalls: nil, toolCallID: nil)]

        if config.conversational == true {
            let existingHistory = ConversationManager.shared.messages(for: match.plugin.manifest.id)
            for msg in existingHistory {
                messages.append(AIMessage(role: AIMessage.Role(rawValue: msg.role) ?? .user, content: msg.content, toolCalls: nil, toolCallID: nil))
            }
        } else if let history {
            for msg in history {
                messages.append(AIMessage(role: AIMessage.Role(rawValue: msg.role) ?? .user, content: msg.content, toolCalls: nil, toolCallID: nil))
            }
        }

        let userMessage = AIMessage(role: .user, content: match.input, toolCalls: nil, toolCallID: nil)
        messages.append(userMessage)

        if config.conversational == true {
            ConversationManager.shared.append(message: ChatMessage(role: "user", content: match.input), for: match.plugin.manifest.id)
        }

        // Tool-call loop
        for _ in 0..<maxToolRounds {
            let response = try await aiClient.chatWithTools(
                messages: messages,
                tools: toolDefs,
                model: config.model,
                temperature: config.temperature,
                maxTokens: config.maxTokens
            )

            switch response {
            case .text(let text):
                // Done — AI returned final text
                if config.conversational == true {
                    ConversationManager.shared.append(
                        message: ChatMessage(role: "assistant", content: text),
                        for: match.plugin.manifest.id
                    )
                }
                let mode = match.plugin.manifest.output?.mode ?? .paste
                return .complete(PluginResult(text: text, outputMode: mode))

            case .toolCalls(let toolCalls):
                // Add assistant message with tool calls to history
                messages.append(AIMessage(role: .assistant, content: nil, toolCalls: toolCalls, toolCallID: nil))

                // Execute each tool and add results
                for call in toolCalls {
                    let toolConfig = config.tools?.first(where: { $0.name == call.name })
                    let result: String

                    if let toolConfig {
                        let toolCallInput = PluginToolRunner.ToolCall(name: call.name, arguments: call.arguments)
                        do {
                            let toolResult = try await PluginToolRunner.run(tool: toolConfig, call: toolCallInput, plugin: match.plugin)
                            result = toolResult.content
                        } catch {
                            result = "Error: \(error.localizedDescription)"
                        }
                    } else {
                        result = "Error: Unknown tool '\(call.name)'"
                    }

                    messages.append(AIMessage(role: .tool, content: result, toolCalls: nil, toolCallID: call.id))
                }
            }
        }

        // Exhausted max rounds — return what we have
        let mode = match.plugin.manifest.output?.mode ?? .paste
        return .complete(PluginResult(text: "Tool execution limit reached. Please try a simpler request.", outputMode: mode))
    }

    // MARK: - Build Tool Definitions

    private static func buildToolDefinitions(from tools: [ToolConfig]) -> [AIToolDefinition] {
        // Builtin tool descriptions and schemas
        let builtinSchemas: [String: (description: String, parameters: [String: Any])] = [
            "web_search": (
                description: "Search the web for information. Returns relevant text results.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "The search query"]
                    ],
                    "required": ["query"]
                ]
            ),
            "read_clipboard": (
                description: "Read the current contents of the user's clipboard.",
                parameters: [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ]
            ),
            "paste": (
                description: "Paste text into the user's active application.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "The text to paste"]
                    ],
                    "required": ["text"]
                ]
            ),
            "run_plugin": (
                description: "Run another OpenTolk plugin and return its output.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "plugin_id": ["type": "string", "description": "The plugin ID to run"],
                        "input": ["type": "string", "description": "Input text for the plugin"]
                    ],
                    "required": ["input"]
                ]
            ),
            "gmail_check": (
                description: "List recent emails from the user's Gmail inbox. Returns subjects, senders, dates, and message IDs.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Gmail search query (e.g. 'is:unread', 'from:sarah', 'subject:meeting'). Leave empty for recent emails."],
                        "max_results": ["type": "number", "description": "Maximum number of emails to return (default 10)"]
                    ] as [String: Any]
                ]
            ),
            "gmail_read": (
                description: "Read the full content of a specific email by its message ID.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "message_id": ["type": "string", "description": "The Gmail message ID to read"]
                    ],
                    "required": ["message_id"]
                ]
            ),
            "gmail_reply": (
                description: "Reply to an existing email. The reply is sent in the same thread.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "message_id": ["type": "string", "description": "The Gmail message ID to reply to"],
                        "body": ["type": "string", "description": "The reply message body text"]
                    ],
                    "required": ["message_id", "body"]
                ]
            ),
            "gmail_send": (
                description: "Send a new email to a recipient.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "to": ["type": "string", "description": "Recipient email address"],
                        "subject": ["type": "string", "description": "Email subject line"],
                        "body": ["type": "string", "description": "Email body text"]
                    ],
                    "required": ["to", "subject", "body"]
                ]
            ),
        ]

        return tools.map { tool -> AIToolDefinition in
            if tool.type == .builtin, let builtin = builtinSchemas[tool.name] {
                return AIToolDefinition(
                    name: tool.name,
                    description: tool.description ?? builtin.description,
                    parameters: tool.parameters?.value as? [String: Any] ?? builtin.parameters
                )
            } else {
                // Script tool or custom
                return AIToolDefinition(
                    name: tool.name,
                    description: tool.description ?? "Tool: \(tool.name)",
                    parameters: tool.parameters?.value as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]]
                )
            }
        }
    }

    // MARK: - Pipeline Execution

    private static func runPipeline(match: PluginMatch, config: PipelineConfig, settings: [String: String]) async throws -> PluginResult {
        var currentInput = match.input

        for step in config.steps {
            guard let plugin = PluginManager.shared.enabledPlugins.first(where: { $0.manifest.id == step.plugin })
                    ?? PluginManager.shared.plugins.first(where: { $0.manifest.id == step.plugin }) else {
                throw PluginRunnerError.pipelinePluginNotFound(step.plugin)
            }

            let syntheticMatch = PluginMatch(
                plugin: plugin,
                trigger: match.trigger,
                triggerWord: "",
                input: currentInput,
                rawInput: currentInput
            )

            let result = try await run(match: syntheticMatch)
            switch result {
            case .complete(let pluginResult):
                currentInput = pluginResult.text
            case .stream(let stream, _):
                // Collect stream into complete text for pipeline
                var collected = ""
                for try await event in stream {
                    if case .textDelta(let delta) = event {
                        collected += delta
                    }
                }
                currentInput = collected
            }
        }

        let mode = match.plugin.manifest.output?.mode ?? .paste
        return PluginResult(text: currentInput, outputMode: mode)
    }

    // MARK: - Script Execution

    private static func runScript(match: PluginMatch, config: ScriptConfig, settings: [String: String]) async throws -> PluginResult {
        let pluginDir = match.plugin.directoryURL
        let dataDir = PluginManager.shared.dataDirectory(for: match.plugin.manifest.id)
        let timeout = TimeInterval(config.timeout ?? 30)

        // Handle inline scripts (single-file plugins)
        let scriptPath: String
        let interpreter: String?

        if let inline = config.inline {
            // Write inline script to temp file
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("opentolk-\(UUID().uuidString).sh")
            try inline.write(to: tempFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempFile.path)
            scriptPath = tempFile.path
            interpreter = config.interpreter ?? "bash"
        } else if let command = config.command {
            scriptPath = pluginDir.appendingPathComponent(command).path
            interpreter = config.interpreter ?? inferInterpreter(for: command)
        } else {
            throw PluginRunnerError.missingCommand
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            if let interpreter {
                process.executableURL = URL(fileURLWithPath: interpreterPath(interpreter))
                process.arguments = interpreterPath(interpreter) == "/usr/bin/env" ? [interpreter, scriptPath] : [scriptPath]
            } else {
                process.executableURL = URL(fileURLWithPath: scriptPath)
            }

            process.currentDirectoryURL = pluginDir
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Environment variables
            var env = ProcessInfo.processInfo.environment
            env["OPENTOLK_INPUT"] = match.input
            env["OPENTOLK_RAW_INPUT"] = match.rawInput
            env["OPENTOLK_TRIGGER"] = match.triggerWord
            env["OPENTOLK_PLUGIN_DIR"] = pluginDir.path
            env["OPENTOLK_DATA_DIR"] = dataDir.path
            for (key, value) in settings {
                env["OPENTOLK_SETTINGS_\(key.uppercased())"] = value
            }
            process.environment = env

            // Timeout
            let timeoutItem = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            process.terminationHandler = { proc in
                timeoutItem.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if proc.terminationStatus != 0 {
                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: PluginRunnerError.timeout)
                    } else {
                        continuation.resume(throwing: PluginRunnerError.scriptFailed(code: proc.terminationStatus, stderr: stderr))
                    }
                    return
                }

                let result = parseOutput(stdout, defaultMode: match.plugin.manifest.output?.mode ?? .paste)
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                timeoutItem.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - HTTP Execution

    private static func runHTTP(match: PluginMatch, config: HTTPConfig, settings: [String: String]) async throws -> PluginResult {
        let url = resolveTemplate(config.url, input: match.input, settings: settings)
        guard let requestURL = URL(string: url) else { throw PluginRunnerError.missingURL }

        var request = URLRequest(url: requestURL)
        request.httpMethod = config.method ?? "POST"
        request.timeoutInterval = TimeInterval(config.timeout ?? 30)

        if let headers = config.headers {
            for (key, value) in headers {
                request.setValue(resolveTemplate(value, input: match.input, settings: settings), forHTTPHeaderField: key)
            }
        }

        if let bodyTemplate = config.body {
            let resolvedBody = resolveTemplateValue(bodyTemplate.value, input: match.input, settings: settings)
            request.httpBody = try JSONSerialization.data(withJSONObject: resolvedBody)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0

        guard (200...299).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PluginRunnerError.httpError(statusCode: statusCode, body: String(body.prefix(500)))
        }

        let responseText: String
        if let jsonPath = config.responseJSONPath {
            responseText = extractJSONPath(data: data, path: jsonPath) ?? String(data: data, encoding: .utf8) ?? ""
        } else {
            responseText = String(data: data, encoding: .utf8) ?? ""
        }

        return parseOutput(responseText, defaultMode: match.plugin.manifest.output?.mode ?? .paste)
    }

    // MARK: - Shortcut Execution

    private static func runShortcut(match: PluginMatch, config: ShortcutConfig, settings: [String: String]) async throws -> PluginResult {
        let timeout = TimeInterval(config.timeout ?? 30)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", config.shortcutName, "--input-path", "-"]
            process.standardInput = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            if let inputData = match.input.data(using: .utf8) {
                let stdinPipe = process.standardInput as! Pipe
                stdinPipe.fileHandleForWriting.write(inputData)
                stdinPipe.fileHandleForWriting.closeFile()
            }

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
                    continuation.resume(throwing: PluginRunnerError.scriptFailed(code: proc.terminationStatus, stderr: stderr))
                    return
                }

                let result = parseOutput(stdout, defaultMode: match.plugin.manifest.output?.mode ?? .paste)
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                timeoutItem.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Template Resolution

    static func resolveTemplate(_ template: String, input: String, settings: [String: String]) -> String {
        var result = template
        result = result.replacingOccurrences(of: "{{input}}", with: input)
        for (key, value) in settings {
            result = result.replacingOccurrences(of: "{{settings.\(key)}}", with: value)
        }
        return result
    }

    private static func resolveTemplateValue(_ value: Any, input: String, settings: [String: String]) -> Any {
        if let string = value as? String {
            return resolveTemplate(string, input: input, settings: settings)
        } else if let array = value as? [Any] {
            return array.map { resolveTemplateValue($0, input: input, settings: settings) }
        } else if let dict = value as? [String: Any] {
            return dict.mapValues { resolveTemplateValue($0, input: input, settings: settings) }
        }
        return value
    }

    // MARK: - JSON Path Extraction

    private static func extractJSONPath(data: Data, path: String) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let components = parseJSONPath(path)
        var current: Any = json

        for component in components {
            switch component {
            case .key(let key):
                guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
                current = next
            case .index(let index):
                guard let array = current as? [Any], index < array.count else { return nil }
                current = array[index]
            }
        }

        if let string = current as? String {
            return string
        } else if let data = try? JSONSerialization.data(withJSONObject: current),
                  let string = String(data: data, encoding: .utf8) {
            return string
        }
        return nil
    }

    private enum PathComponent {
        case key(String)
        case index(Int)
    }

    private static func parseJSONPath(_ path: String) -> [PathComponent] {
        var components: [PathComponent] = []
        var current = ""

        for char in path {
            switch char {
            case ".":
                if !current.isEmpty {
                    components.append(.key(current))
                    current = ""
                }
            case "[":
                if !current.isEmpty {
                    components.append(.key(current))
                    current = ""
                }
            case "]":
                if let index = Int(current) {
                    components.append(.index(index))
                }
                current = ""
            default:
                current.append(char)
            }
        }

        if !current.isEmpty {
            components.append(.key(current))
        }

        return components
    }

    // MARK: - Output Parsing

    static func parseOutput(_ raw: String, defaultMode: OutputMode) -> PluginResult {
        // Try JSON format
        if raw.hasPrefix("{"),
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            let mode: OutputMode
            if let outputStr = json["output"] as? String, let parsed = OutputMode(rawValue: outputStr) {
                mode = parsed
            } else {
                mode = defaultMode
            }
            return PluginResult(text: text, outputMode: mode)
        }

        // Try directive prefix
        if raw.hasPrefix("@output:") {
            let afterPrefix = raw.dropFirst("@output:".count)
            if let newlineIndex = afterPrefix.firstIndex(of: "\n") {
                let modeStr = String(afterPrefix[afterPrefix.startIndex..<newlineIndex])
                let text = String(afterPrefix[afterPrefix.index(after: newlineIndex)...])
                if let mode = OutputMode(rawValue: modeStr) {
                    return PluginResult(text: text, outputMode: mode)
                }
            }
        }

        return PluginResult(text: raw, outputMode: defaultMode)
    }

    // MARK: - Interpreter Helpers

    private static func inferInterpreter(for command: String) -> String? {
        let ext = (command as NSString).pathExtension.lowercased()
        switch ext {
        case "sh": return "bash"
        case "py": return "python3"
        case "js": return "node"
        case "rb": return "ruby"
        case "swift": return "swift"
        default: return nil
        }
    }

    private static func interpreterPath(_ interpreter: String) -> String {
        switch interpreter {
        case "bash": return "/bin/bash"
        case "zsh": return "/bin/zsh"
        case "python3", "python": return "/usr/bin/env"
        case "node": return "/usr/bin/env"
        case "ruby": return "/usr/bin/env"
        case "swift": return "/usr/bin/env"
        default: return "/usr/bin/env"
        }
    }
}
