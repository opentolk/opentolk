import Foundation

enum PluginRouter {

    /// Attempts to match transcribed text against all enabled plugins' triggers.
    /// Returns the best match or nil if no plugin matches.
    /// Now async to support intent-based routing with AI classification.
    static func route(_ text: String) async -> PluginMatch? {
        guard Config.shared.pluginsEnabled else { return nil }

        let plugins = PluginManager.shared.enabledPlugins
        guard !plugins.isEmpty else { return nil }

        // Phase 1: Deterministic matching (keyword + regex) — instant
        var bestMatch: PluginMatch?
        var bestPriority = Int.min
        var bestTriggerLength = 0

        for plugin in plugins {
            if let result = matchTrigger(plugin.manifest.trigger, against: text, plugin: plugin) {
                let priority = triggerPriority(plugin.manifest.trigger)
                let triggerLen = result.triggerWord.count

                if priority > bestPriority || (priority == bestPriority && triggerLen > bestTriggerLength) {
                    bestMatch = result
                    bestPriority = priority
                    bestTriggerLength = triggerLen
                }
            }
        }

        // If we found a deterministic match, return it
        if bestMatch != nil { return bestMatch }

        // Phase 2: Intent-based routing (AI classification) — only if no deterministic match
        let intentPlugins = plugins.filter {
            if case .intent = $0.manifest.trigger { return true }
            return false
        }

        if !intentPlugins.isEmpty {
            if let intentMatch = await classifyIntent(text: text, plugins: intentPlugins) {
                return intentMatch
            }
        }

        // Phase 3: Catch-all — lowest priority
        for plugin in plugins {
            if case .catchAll = plugin.manifest.trigger {
                return PluginMatch(
                    plugin: plugin,
                    trigger: plugin.manifest.trigger,
                    triggerWord: "",
                    input: text,
                    rawInput: text
                )
            }
        }

        return nil
    }

    // MARK: - Trigger Matching

    private static func matchTrigger(_ trigger: TriggerConfig, against text: String, plugin: LoadedPlugin) -> PluginMatch? {
        switch trigger {
        case .keyword(let config):
            return matchKeyword(config, trigger: trigger, against: text, plugin: plugin)
        case .regex(let config):
            return matchRegex(config, trigger: trigger, against: text, plugin: plugin)
        case .intent, .catchAll:
            return nil  // Handled separately
        }
    }

    // MARK: - Keyword Matching

    private static func matchKeyword(_ config: KeywordTrigger, trigger: TriggerConfig, against text: String, plugin: LoadedPlugin) -> PluginMatch? {
        let lowerText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let position = config.position ?? .start

        let sortedKeywords = config.keywords.sorted { $0.count > $1.count }

        for keyword in sortedKeywords {
            let lowerKeyword = keyword.lowercased()

            let matched: Bool
            switch position {
            case .start:
                matched = lowerText.hasPrefix(lowerKeyword) &&
                    (lowerText.count == lowerKeyword.count ||
                     !lowerText[lowerText.index(lowerText.startIndex, offsetBy: lowerKeyword.count)].isLetter)
            case .end:
                matched = lowerText.hasSuffix(lowerKeyword) &&
                    (lowerText.count == lowerKeyword.count ||
                     !lowerText[lowerText.index(lowerText.endIndex, offsetBy: -(lowerKeyword.count + 1))].isLetter)
            case .anywhere:
                matched = lowerText.contains(lowerKeyword)
            }

            if matched {
                let input = stripTrigger(config.stripTrigger, keyword: keyword, from: text)
                return PluginMatch(
                    plugin: plugin,
                    trigger: trigger,
                    triggerWord: keyword,
                    input: input,
                    rawInput: text
                )
            }
        }

        return nil
    }

    // MARK: - Regex Matching

    private static func matchRegex(_ config: RegexTrigger, trigger: TriggerConfig, against text: String, plugin: LoadedPlugin) -> PluginMatch? {
        guard let regex = try? NSRegularExpression(pattern: config.pattern, options: .caseInsensitive) else { return nil }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }

        let matchedString = String(text[Range(match.range, in: text)!])
        let input = stripTrigger(config.stripTrigger, keyword: matchedString, from: text)

        return PluginMatch(
            plugin: plugin,
            trigger: trigger,
            triggerWord: matchedString,
            input: input,
            rawInput: text
        )
    }

    // MARK: - Intent Classification (AI-based)

    private static func classifyIntent(text: String, plugins: [LoadedPlugin]) async -> PluginMatch? {
        // Build classification prompt
        var pluginDescriptions: [String] = []
        for plugin in plugins {
            guard case .intent(let config) = plugin.manifest.trigger else { continue }
            var desc = "Plugin ID: \(plugin.manifest.id)\nIntents: \(config.intents.joined(separator: ", "))"
            if let examples = config.examples, !examples.isEmpty {
                desc += "\nExamples: \(examples.joined(separator: "; "))"
            }
            pluginDescriptions.append(desc)
        }

        let classificationPrompt = """
        You are a plugin router. Given user text, determine which plugin best matches.
        Respond with ONLY the plugin ID, or "none" if no plugin matches.

        Available plugins:
        \(pluginDescriptions.joined(separator: "\n\n"))

        User text: \(text)
        """

        guard let aiClient = AIClientFactory.makeClient() else {
            // No API key configured — can't do intent classification
            return nil
        }
        let messages = [
            ChatMessage(role: "system", content: "You are a classification assistant. Respond with only a plugin ID or 'none'."),
            ChatMessage(role: "user", content: classificationPrompt)
        ]

        do {
            let response = try await aiClient.chat(messages: messages, model: nil, temperature: 0.0, maxTokens: 100)
            let pluginID = response.trimmingCharacters(in: .whitespacesAndNewlines)

            guard pluginID != "none",
                  let matchedPlugin = plugins.first(where: { $0.manifest.id == pluginID }) else {
                return nil
            }

            return PluginMatch(
                plugin: matchedPlugin,
                trigger: matchedPlugin.manifest.trigger,
                triggerWord: "",
                input: text,
                rawInput: text
            )
        } catch {
            print("[PluginRouter] Intent classification failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Priority

    private static func triggerPriority(_ trigger: TriggerConfig) -> Int {
        switch trigger {
        case .keyword: return 10
        case .regex: return 5
        case .intent: return 3
        case .catchAll: return 0
        }
    }

    // MARK: - Strip Trigger

    private static func stripTrigger(_ shouldStrip: Bool?, keyword: String, from text: String) -> String {
        guard shouldStrip == true else { return text }

        let lowerText = text.lowercased()
        let lowerKeyword = keyword.lowercased()

        guard let range = lowerText.range(of: lowerKeyword) else { return text }

        var result = text
        result.removeSubrange(range)
        return result.trimmingCharacters(in: .whitespaces)
    }
}
