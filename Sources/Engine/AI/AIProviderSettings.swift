import Foundation

/// Where "AI 改写" sends text. One OpenAI-compatible endpoint (`POST {baseURL}/chat/completions`)
/// covers OpenAI, DeepSeek, Kimi, 智谱, SiliconFlow, OpenRouter, 火山方舟, Ollama, LM Studio —
/// the Base URL field is what makes that possible. Everything, the API key included, lives
/// in UserDefaults: the Keychain item asked for the login password on every settings visit
/// (each Dev build re-signs and loses the ACL), and the key never leaves this machine anyway.
enum AIProviderSettings {
    static let baseURLKey = "aiServiceBaseURL"
    static let apiKeyKey = "aiServiceAPIKey"
    static let modelKey = "aiServiceModel"
    static let timeoutKey = "aiServiceTimeoutSeconds"
    static let temperatureKey = "aiServiceTemperature"
    static let thinkingKey = "aiServiceThinking"
    static let presetKey = "aiServicePreset"

    /// Hard cap on what a single transform may send. Guards the bill and the timeout.
    static let maxContentLength = 8000

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLKey) }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelKey) }
    }

    static var timeoutSeconds: Double {
        get {
            let v = UserDefaults.standard.double(forKey: timeoutKey)
            return v > 0 ? v : 60
        }
        set { UserDefaults.standard.set(newValue, forKey: timeoutKey) }
    }

    static var temperature: Double {
        get {
            guard UserDefaults.standard.object(forKey: temperatureKey) != nil else { return 0.3 }
            return UserDefaults.standard.double(forKey: temperatureKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: temperatureKey) }
    }

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: apiKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: apiKeyKey) }
    }

    static var thinking: AIThinkingMode {
        get { AIThinkingMode(rawValue: UserDefaults.standard.string(forKey: thinkingKey) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: thinkingKey) }
    }

    /// Local servers (Ollama, LM Studio) take no key; everything else does.
    static var isConfigured: Bool {
        !baseURL.isEmpty && !model.isEmpty
    }

    static func snapshot() -> AIClientConfig {
        AIClientConfig(baseURL: baseURL, apiKey: apiKey, model: model,
                       timeout: timeoutSeconds, temperature: temperature, thinking: thinking)
    }
}

/// Reasoning models spend seconds "thinking" before a one-line rewrite. The knob isn't
/// standardised: 火山方舟 / DeepSeek / 智谱 take `thinking: {type}`, Qwen-style servers take
/// `enable_thinking`, and OpenAI rejects both with a 400. So `.auto` sends nothing.
enum AIThinkingMode: String, CaseIterable, Sendable, Codable {
    case auto, off, on
}

/// One-click Base URL + default model. Shown as a Picker; picking one only fills the
/// fields, the user can still edit them.
enum AIProviderPreset: String, CaseIterable, Identifiable {
    case custom
    case openai, deepseek, kimi, zhipu, siliconflow, openrouter, volcengine, ollama, lmstudio

    var id: String { rawValue }

    @MainActor var displayName: String {
        switch self {
        case .custom: L10n.tr("settings.aiService.preset.custom")
        case .openai: "OpenAI"
        case .deepseek: "DeepSeek"
        case .kimi: "Kimi (Moonshot)"
        case .zhipu: "智谱 GLM"
        case .siliconflow: "SiliconFlow"
        case .openrouter: "OpenRouter"
        case .volcengine: "火山方舟"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        }
    }

    var baseURL: String {
        switch self {
        case .custom: ""
        case .openai: "https://api.openai.com/v1"
        case .deepseek: "https://api.deepseek.com/v1"
        case .kimi: "https://api.moonshot.cn/v1"
        case .zhipu: "https://open.bigmodel.cn/api/paas/v4"
        case .siliconflow: "https://api.siliconflow.cn/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .volcengine: "https://ark.cn-beijing.volces.com/api/v3"
        case .ollama: "http://localhost:11434/v1"
        case .lmstudio: "http://localhost:1234/v1"
        }
    }

    /// Providers whose default models think unless told not to.
    var defaultThinking: AIThinkingMode {
        switch self {
        case .deepseek, .zhipu, .siliconflow, .volcengine, .kimi: .off
        case .custom, .openai, .openrouter, .ollama, .lmstudio: .auto
        }
    }

    var defaultModel: String {
        switch self {
        case .custom: ""
        case .openai: "gpt-4o-mini"
        case .deepseek: "deepseek-chat"
        case .kimi: "moonshot-v1-8k"
        case .zhipu: "glm-4-flash"
        case .siliconflow: "Qwen/Qwen2.5-7B-Instruct"
        case .openrouter: "openai/gpt-4o-mini"
        case .volcengine: ""
        case .ollama: "llama3.1"
        case .lmstudio: ""
        }
    }
}
