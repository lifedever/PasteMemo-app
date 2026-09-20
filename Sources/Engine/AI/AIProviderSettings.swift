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

    // Local-CLI backend. Separate keys from the hosted ones so switching modes back and
    // forth doesn't make the user retype either side.
    static let modeKey = "aiServiceMode"
    static let cliPresetKey = "aiServiceCLIPreset"
    static let cliExecutableKey = "aiServiceCLIExecutable"
    /// Only for a named preset whose binary wasn't found on the search path. Kept apart
    /// from `cliExecutableKey` so switching presets never clobbers a Custom setup.
    static let cliExecutableOverrideKey = "aiServiceCLIExecutableOverride"
    static let cliArgumentsKey = "aiServiceCLIArguments"
    static let cliModelKey = "aiServiceCLIModel"
    static let cliOutputKeyKey = "aiServiceCLIOutputKey"
    static let cliTimeoutKey = "aiServiceCLITimeoutSeconds"

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

    // MARK: - Local CLI

    static var mode: AIServiceMode {
        get { AIServiceMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .remote }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    static var cliExecutable: String {
        get { UserDefaults.standard.string(forKey: cliExecutableKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: cliExecutableKey) }
    }

    static var cliExecutableOverride: String {
        get { UserDefaults.standard.string(forKey: cliExecutableOverrideKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: cliExecutableOverrideKey) }
    }

    /// Empty = whatever the agent is configured to use on its own.
    static var cliModel: String {
        get { UserDefaults.standard.string(forKey: cliModelKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: cliModelKey) }
    }

    static var cliArguments: String {
        get { UserDefaults.standard.string(forKey: cliArgumentsKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: cliArgumentsKey) }
    }

    static var cliOutputJSONKey: String {
        get { UserDefaults.standard.string(forKey: cliOutputKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: cliOutputKeyKey) }
    }

    /// Longer default than the hosted path: a CLI pays for process start and session
    /// setup before the model even begins, measured at 4–8s for a one-line rewrite.
    static var cliTimeoutSeconds: Double {
        get {
            let v = UserDefaults.standard.double(forKey: cliTimeoutKey)
            return v > 0 ? v : 120
        }
        set { UserDefaults.standard.set(newValue, forKey: cliTimeoutKey) }
    }

    static var cliPreset: AICLIPreset {
        get { AICLIPreset(rawValue: UserDefaults.standard.string(forKey: cliPresetKey) ?? "") ?? .custom }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: cliPresetKey) }
    }

    /// Local servers (Ollama, LM Studio) take no key; everything else does.
    static var isConfigured: Bool {
        switch mode {
        case .remote: !baseURL.isEmpty && !model.isEmpty
        case .local: !cliSnapshot().executable.isEmpty
        }
    }

    static func snapshot() -> AIClientConfig {
        AIClientConfig(baseURL: baseURL, apiKey: apiKey, model: model,
                       timeout: timeoutSeconds, temperature: temperature, thinking: thinking)
    }

    /// For a named agent the arguments come from the preset, not from storage — the user
    /// never sees those fields, and tying them to the preset means a later correction to
    /// the flags reaches everyone instead of only new installs. The executable stays
    /// overridable: that's the one thing that legitimately differs per machine.
    static func cliSnapshot() -> AICLIConfig {
        let preset = cliPreset
        guard preset != .custom else {
            return AICLIConfig(executable: cliExecutable, arguments: cliArguments,
                               outputJSONKey: cliOutputJSONKey, timeout: cliTimeoutSeconds)
        }
        var arguments = preset.arguments
        let model = cliModel
        if !model.isEmpty, !preset.modelFlag.isEmpty {
            // Single-quoted so the tokenizer keeps it as one argument. Stray quotes are
            // dropped rather than escaped: no real model name contains one, and this way
            // the value can't break out of its argument.
            let safe = model.replacingOccurrences(of: "'", with: "")
            arguments += " \(preset.modelFlag) '\(safe)'"
        }
        return AICLIConfig(
            executable: cliExecutableOverride.isEmpty ? preset.executable : cliExecutableOverride,
            arguments: arguments,
            outputJSONKey: preset.outputJSONKey,
            timeout: cliTimeoutSeconds
        )
    }
}

/// Where a transform runs. Exclusive by design — "which AI does PasteMemo use" is one
/// answer, not a per-action choice; the rule editor stays free of backend pickers.
enum AIServiceMode: String, CaseIterable, Sendable {
    /// An OpenAI-compatible HTTP endpoint.
    case remote
    /// A CLI installed on this Mac, carrying its own auth.
    case local
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

/// Starting points for the local-CLI fields. Picking one fills the three fields below it;
/// every field stays editable, and `.custom` leaves them alone — a CLI nobody here has
/// heard of is configured the same way the built-in two are, not through a code change.
enum AICLIPreset: String, CaseIterable, Identifiable {
    case custom
    case claudeCode, codex

    var id: String { rawValue }

    @MainActor var displayName: String {
        switch self {
        case .custom: L10n.tr("settings.aiService.cli.preset.custom")
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        }
    }

    var executable: String {
        switch self {
        case .custom: ""
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }

    /// `--max-turns 1` / `--sandbox read-only` matter: without them an agentic CLI may go
    /// off reading files to "research" a clipboard rewrite. `--ephemeral` keeps a
    /// clipboard transform out of the user's Codex session history.
    var arguments: String {
        switch self {
        case .custom: ""
        case .claudeCode: "-p {prompt} --output-format json --max-turns 1"
        case .codex: "exec {prompt} --sandbox read-only --ephemeral"
        }
    }

    /// Claude's JSON envelope carries the answer in `result`; `codex exec` prints the
    /// final message to stdout by itself and needs no unwrapping.
    var outputJSONKey: String {
        switch self {
        case .custom, .codex: ""
        case .claudeCode: "result"
        }
    }

    /// Flag that overrides the model the CLI would otherwise pick from its own config.
    /// Both agents spell it the same way. Empty for Custom — there the user writes the
    /// whole command line, model flag included.
    var modelFlag: String {
        switch self {
        case .custom: ""
        case .claudeCode, .codex: "--model"
        }
    }

    /// Config files that exist once the CLI has been set up, used to tell the user
    /// "installed but not logged in" apart from "not installed".
    var configPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch self {
        case .custom: return []
        case .claudeCode: return ["\(home)/.claude", "\(home)/.claude.json"]
        case .codex: return ["\(home)/.config/codex", "\(home)/.codex"]
        }
    }

    /// Resolved binary path, or nil when the CLI isn't installed.
    var detectedPath: String? {
        guard self != .custom else { return nil }
        return CLIResolver.resolve(executable)
    }

    var hasConfig: Bool {
        configPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }
}
