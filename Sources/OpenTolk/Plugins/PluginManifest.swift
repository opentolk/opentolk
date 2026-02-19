import Foundation

// MARK: - Plugin Manifest

struct PluginManifest: Codable {
    let id: String                    // reverse-DNS: com.author.name
    let name: String
    let version: String
    let description: String
    let author: AuthorInfo?
    let icon: String?
    let categories: [String]?
    let permissions: [PluginPermission]?
    let minAppVersion: String?
    let homepage: String?
    let repository: String?
    let license: String?

    let trigger: TriggerConfig
    let execution: PluginExecutionConfig
    let output: PluginOutput?
    let settings: [PluginSetting]?

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, author, icon, categories, permissions
        case minAppVersion = "min_app_version"
        case homepage, repository, license, trigger, execution, output, settings
    }
}

struct AuthorInfo: Codable {
    let name: String
    let url: String?
}

// MARK: - Permissions

enum PluginPermission: String, Codable {
    case network
    case filesystem
    case clipboard
    case notifications
    case ai
    case microphone
    case gmail
}

// MARK: - Trigger Config (Discriminated Union)

enum TriggerConfig: Codable {
    case keyword(KeywordTrigger)
    case regex(RegexTrigger)
    case intent(IntentTrigger)
    case catchAll

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "keyword":
            self = .keyword(try KeywordTrigger(from: decoder))
        case "regex":
            self = .regex(try RegexTrigger(from: decoder))
        case "intent":
            self = .intent(try IntentTrigger(from: decoder))
        case "catch_all":
            self = .catchAll
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown trigger type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keyword(let config):
            try container.encode("keyword", forKey: .type)
            try config.encode(to: encoder)
        case .regex(let config):
            try container.encode("regex", forKey: .type)
            try config.encode(to: encoder)
        case .intent(let config):
            try container.encode("intent", forKey: .type)
            try config.encode(to: encoder)
        case .catchAll:
            try container.encode("catch_all", forKey: .type)
        }
    }
}

struct KeywordTrigger: Codable {
    let keywords: [String]
    let position: TriggerPosition?
    let stripTrigger: Bool?

    enum CodingKeys: String, CodingKey {
        case keywords, position
        case stripTrigger = "strip_trigger"
    }
}

struct RegexTrigger: Codable {
    let pattern: String
    let stripTrigger: Bool?

    enum CodingKeys: String, CodingKey {
        case pattern
        case stripTrigger = "strip_trigger"
    }
}

struct IntentTrigger: Codable {
    let intents: [String]
    let examples: [String]?
}

enum TriggerPosition: String, Codable {
    case start
    case end
    case anywhere
}

// MARK: - Execution Config (Discriminated Union)

enum PluginExecutionConfig: Codable {
    case script(ScriptConfig)
    case http(HTTPConfig)
    case shortcut(ShortcutConfig)
    case ai(AIConfig)
    case pipeline(PipelineConfig)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "script":
            self = .script(try ScriptConfig(from: decoder))
        case "http":
            self = .http(try HTTPConfig(from: decoder))
        case "shortcut":
            self = .shortcut(try ShortcutConfig(from: decoder))
        case "ai":
            self = .ai(try AIConfig(from: decoder))
        case "pipeline":
            self = .pipeline(try PipelineConfig(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown execution type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .script(let config):
            try container.encode("script", forKey: .type)
            try config.encode(to: encoder)
        case .http(let config):
            try container.encode("http", forKey: .type)
            try config.encode(to: encoder)
        case .shortcut(let config):
            try container.encode("shortcut", forKey: .type)
            try config.encode(to: encoder)
        case .ai(let config):
            try container.encode("ai", forKey: .type)
            try config.encode(to: encoder)
        case .pipeline(let config):
            try container.encode("pipeline", forKey: .type)
            try config.encode(to: encoder)
        }
    }
}

struct ScriptConfig: Codable {
    let command: String?
    let inline: String?
    let interpreter: String?
    let timeout: Int?
}

struct HTTPConfig: Codable {
    let url: String
    let method: String?
    let headers: [String: String]?
    let body: AnyCodable?
    let responseJSONPath: String?
    let timeout: Int?

    enum CodingKeys: String, CodingKey {
        case url, method, headers, body
        case responseJSONPath = "response_json_path"
        case timeout
    }
}

struct ShortcutConfig: Codable {
    let shortcutName: String
    let timeout: Int?

    enum CodingKeys: String, CodingKey {
        case shortcutName = "shortcut_name"
        case timeout
    }
}

struct AIConfig: Codable {
    let model: String?
    let systemPrompt: String?
    let systemPromptFile: String?
    let temperature: Double?
    let maxTokens: Int?
    let streaming: Bool?
    let conversational: Bool?
    let tools: [ToolConfig]?

    enum CodingKeys: String, CodingKey {
        case model
        case systemPrompt = "system_prompt"
        case systemPromptFile = "system_prompt_file"
        case temperature
        case maxTokens = "max_tokens"
        case streaming, conversational, tools
    }
}

struct ToolConfig: Codable {
    let name: String
    let type: ToolType
    let description: String?
    let command: String?
    let config: [String: String]?
    let parameters: AnyCodable?

    enum ToolType: String, Codable {
        case builtin
        case script
    }
}

struct PipelineConfig: Codable {
    let steps: [PipelineStep]
}

struct PipelineStep: Codable {
    let plugin: String
    let settingsOverride: [String: String]?

    enum CodingKeys: String, CodingKey {
        case plugin
        case settingsOverride = "settings_override"
    }
}

// MARK: - Output

struct PluginOutput: Codable {
    let mode: OutputMode
    let fallback: OutputMode?
    let also: [OutputMode]?
    let format: OutputFormat?
}

enum OutputMode: String, Codable {
    case paste
    case clipboard
    case notify
    case speak
    case panel
    case store
    case silent
    case reply
}

enum OutputFormat: String, Codable {
    case plain
    case markdown
}

// MARK: - Settings

enum SettingType: String, Codable {
    case string
    case secret
    case select
    case bool
    case text
    case number
}

struct PluginSetting: Codable {
    let key: String
    let label: String
    let type: SettingType
    let required: Bool?
    let options: [String]?
    let `default`: AnyCodable?
    let placeholder: String?
}

// MARK: - Loaded Plugin (runtime wrapper)

struct LoadedPlugin: Identifiable {
    var id: String { manifest.id }
    let manifest: PluginManifest
    let directoryURL: URL
    var isEnabled: Bool
}

// MARK: - Plugin Match

struct PluginMatch {
    let plugin: LoadedPlugin
    let trigger: TriggerConfig
    let triggerWord: String
    let input: String
    let rawInput: String
}

// MARK: - Plugin Result

struct PluginResult {
    let text: String
    let outputMode: OutputMode?
}

// MARK: - Chat Message

struct ChatMessage: Codable {
    let role: String    // "system", "user", "assistant"
    let content: String
}

// MARK: - AnyCodable

struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}
