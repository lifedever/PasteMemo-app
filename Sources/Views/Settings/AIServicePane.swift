import SwiftUI

/// 设置 → AI 服务：PasteMemo 调用的模型接口（方向与「AI Agents」相反——那页是外部 Agent 读 PasteMemo）。
/// 只做 OpenAI 兼容协议，Base URL 可填就覆盖了所有主流服务商和本地模型。
struct AIServicePane: View {
    @AppStorage(AIProviderSettings.presetKey) private var presetRaw = AIProviderPreset.custom.rawValue
    @AppStorage(AIProviderSettings.baseURLKey) private var baseURL = ""
    @AppStorage(AIProviderSettings.modelKey) private var model = ""
    @AppStorage(AIProviderSettings.timeoutKey) private var timeout: Double = 60
    @AppStorage(AIProviderSettings.temperatureKey) private var temperature: Double = 0.3
    @AppStorage(AIProviderSettings.thinkingKey) private var thinkingRaw = AIThinkingMode.auto.rawValue
    @AppStorage(AIProviderSettings.apiKeyKey) private var apiKey = ""
    @State private var revealKey = false
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, running, ok(String), failed(String)
    }

    private var preset: AIProviderPreset {
        AIProviderPreset(rawValue: presetRaw) ?? .custom
    }

    var body: some View {
        Form {
            Section {
                Picker(L10n.tr("settings.aiService.provider"), selection: Binding(
                    get: { preset },
                    set: { applyPreset($0) }
                )) {
                    ForEach(AIProviderPreset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                TextField("Base URL", text: $baseURL, prompt: Text("https://api.openai.com/v1"))
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .onChange(of: baseURL) { _, _ in testState = .idle }
                HStack(spacing: 6) {
                    if revealKey {
                        // Plain field: select-all + ⌘C is the way to copy the key out.
                        TextField("API Key", text: $apiKey)
                            .autocorrectionDisabled()
                            .textSelection(.enabled)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("API Key", text: $apiKey)
                    }
                    Button {
                        revealKey.toggle()
                    } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.tr(revealKey ? "settings.aiService.hideKey" : "settings.aiService.showKey"))
                }
                .onChange(of: apiKey) { _, _ in testState = .idle }
                TextField(L10n.tr("settings.aiService.model"), text: $model, prompt: Text("gpt-4o-mini"))
                    .autocorrectionDisabled()
                    .onChange(of: model) { _, _ in testState = .idle }
            } footer: {
                Text(L10n.tr("settings.aiService.privacyHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: $timeout, in: 10...180, step: 10) {
                    LabeledContent(L10n.tr("settings.aiService.timeout")) {
                        Text(L10n.tr("settings.aiService.timeout.seconds", Int(timeout)))
                    }
                }
                Picker(L10n.tr("settings.aiService.thinking"), selection: Binding(
                    get: { AIThinkingMode(rawValue: thinkingRaw) ?? .auto },
                    set: { thinkingRaw = $0.rawValue; testState = .idle }
                )) {
                    Text(L10n.tr("settings.aiService.thinking.auto")).tag(AIThinkingMode.auto)
                    Text(L10n.tr("settings.aiService.thinking.off")).tag(AIThinkingMode.off)
                    Text(L10n.tr("settings.aiService.thinking.on")).tag(AIThinkingMode.on)
                }
                LabeledContent(L10n.tr("settings.aiService.temperature")) {
                    HStack {
                        Slider(value: $temperature, in: 0...1, step: 0.1)
                            .frame(width: 160)
                        Text(String(format: "%.1f", temperature))
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("settings.aiService.usageHint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.tr("settings.automation.manage")) {
                        AutomationManagerWindow.show()
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }

            Section {
                HStack(spacing: 12) {
                    Button(L10n.tr("settings.aiService.test")) { runTest() }
                        .disabled(testState == .running || !AIProviderSettings.isConfigured)
                    switch testState {
                    case .idle:
                        EmptyView()
                    case .running:
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("settings.aiService.testing")).foregroundStyle(.secondary)
                    case .ok(let reply):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(L10n.tr("settings.aiService.test.ok", reply)).foregroundStyle(.secondary)
                    case .failed(let message):
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text(L10n.tr("settings.aiService.test.failed", message))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func applyPreset(_ p: AIProviderPreset) {
        presetRaw = p.rawValue
        guard p != .custom else { return }
        baseURL = p.baseURL
        if !p.defaultModel.isEmpty { model = p.defaultModel }
        thinkingRaw = p.defaultThinking.rawValue
        testState = .idle
    }

    private func runTest() {
        testState = .running
        let client = AIClient(config: AIProviderSettings.snapshot())
        Task {
            do {
                let reply = try await client.testConnection()
                testState = .ok(String(reply.prefix(40)))
            } catch let error as AIError {
                testState = .failed(error.userMessage)
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
