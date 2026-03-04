import Foundation

final class Config {
    static let shared = Config()
    static let apiBaseURL = "https://opentolk-api.opentolk.workers.dev"

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let silenceThresholdRMS = "silenceThresholdRMS"
        static let silenceDuration = "silenceDuration"
        static let holdThresholdMs = "holdThresholdMs"
        static let maxRecordingDuration = "maxRecordingDuration"
        static let groqModel = "groqModel"
        static let language = "language"
        static let selectedProvider = "selectedProvider"
        static let selectedMicrophoneID = "selectedMicrophoneID"
        static let pluginsEnabled = "pluginsEnabled"
        static let snippetsEnabled = "snippetsEnabled"
        static let hotkeyCode = "hotkeyCode"
        static let configUpdatedAt = "configUpdatedAt"
        static let aiAPIKey = "aiAPIKey"
        static let aiProvider = "aiProvider"
        static let localModel = "localModel"
    }

    private init() {
        defaults.register(defaults: [
            Keys.silenceThresholdRMS: 0.01,
            Keys.silenceDuration: 1.0,
            Keys.holdThresholdMs: 150,
            Keys.maxRecordingDuration: 120.0,
            Keys.groqModel: "whisper-large-v3-turbo",
            Keys.language: "en",
            Keys.selectedProvider: TranscriptionProviderType.cloud.rawValue,
            Keys.selectedMicrophoneID: "",
            Keys.pluginsEnabled: true,
            Keys.snippetsEnabled: true,
            Keys.hotkeyCode: HotkeyOption.rightOption.rawValue,
            Keys.localModel: "large-v3_turbo",
        ])
    }

    var silenceThresholdRMS: Float {
        get { defaults.float(forKey: Keys.silenceThresholdRMS) }
        set { defaults.set(newValue, forKey: Keys.silenceThresholdRMS); markConfigUpdated() }
    }

    var silenceDuration: TimeInterval {
        get { defaults.double(forKey: Keys.silenceDuration) }
        set { defaults.set(newValue, forKey: Keys.silenceDuration); markConfigUpdated() }
    }

    var holdThresholdMs: Int {
        get { defaults.integer(forKey: Keys.holdThresholdMs) }
        set { defaults.set(newValue, forKey: Keys.holdThresholdMs); markConfigUpdated() }
    }

    var maxRecordingDuration: TimeInterval {
        get { defaults.double(forKey: Keys.maxRecordingDuration) }
        set { defaults.set(newValue, forKey: Keys.maxRecordingDuration); markConfigUpdated() }
    }

    var groqModel: String {
        get { defaults.string(forKey: Keys.groqModel) ?? "whisper-large-v3-turbo" }
        set { defaults.set(newValue, forKey: Keys.groqModel); markConfigUpdated() }
    }

    var language: String {
        get { defaults.string(forKey: Keys.language) ?? "en" }
        set { defaults.set(newValue, forKey: Keys.language); markConfigUpdated() }
    }

    var selectedMicrophoneID: String {
        get { defaults.string(forKey: Keys.selectedMicrophoneID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.selectedMicrophoneID) }
    }

    var selectedProvider: TranscriptionProviderType {
        get {
            let raw = defaults.string(forKey: Keys.selectedProvider) ?? TranscriptionProviderType.cloud.rawValue
            return TranscriptionProviderType(rawValue: raw) ?? .cloud
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.selectedProvider)
            NotificationCenter.default.post(name: .transcriptionProviderChanged, object: nil)
        }
    }

    var pluginsEnabled: Bool {
        get { defaults.bool(forKey: Keys.pluginsEnabled) }
        set { defaults.set(newValue, forKey: Keys.pluginsEnabled); markConfigUpdated() }
    }

    var snippetsEnabled: Bool {
        get { defaults.bool(forKey: Keys.snippetsEnabled) }
        set { defaults.set(newValue, forKey: Keys.snippetsEnabled); markConfigUpdated() }
    }

    var hotkeyCode: HotkeyOption {
        get {
            let raw = defaults.string(forKey: Keys.hotkeyCode) ?? HotkeyOption.rightOption.rawValue
            return HotkeyOption(rawValue: raw) ?? .rightOption
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.hotkeyCode)
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        }
    }

    /// AI API key for direct provider access (user's own key)
    var aiAPIKey: String? {
        get { KeychainHelper.load(key: "opentolk.aiAPIKey") }
        set {
            if let newValue {
                KeychainHelper.save(key: "opentolk.aiAPIKey", value: newValue)
            } else {
                KeychainHelper.delete(key: "opentolk.aiAPIKey")
            }
        }
    }

    var localModel: String {
        get { defaults.string(forKey: Keys.localModel) ?? "large-v3_turbo" }
        set { defaults.set(newValue, forKey: Keys.localModel); markConfigUpdated() }
    }

    /// AI provider: "openai" or "anthropic"
    var aiProvider: String {
        get { defaults.string(forKey: Keys.aiProvider) ?? "openai" }
        set { defaults.set(newValue, forKey: Keys.aiProvider) }
    }

    var configUpdatedAt: Date {
        get {
            let interval = defaults.double(forKey: Keys.configUpdatedAt)
            return interval > 0 ? Date(timeIntervalSince1970: interval) : Date(timeIntervalSince1970: 0)
        }
        set {
            defaults.set(newValue.timeIntervalSince1970, forKey: Keys.configUpdatedAt)
        }
    }

    /// Call when a sync-relevant setting changes.
    private func markConfigUpdated() {
        configUpdatedAt = Date()
        NotificationCenter.default.post(name: .localDataChanged, object: nil)
    }

    // MARK: - Computed Properties

    var effectiveMaxRecordingDuration: TimeInterval {
        return maxRecordingDuration
    }

    var effectiveLanguage: String {
        return language
    }
}
