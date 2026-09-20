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
    @AppStorage(AIProviderSettings.modeKey) private var modeRaw = AIServiceMode.remote.rawValue
    @AppStorage(AIProviderSettings.cliPresetKey) private var cliPresetRaw = AICLIPreset.custom.rawValue
    @AppStorage(AIProviderSettings.cliExecutableKey) private var cliExecutable = ""
    @AppStorage(AIProviderSettings.cliExecutableOverrideKey) private var cliExecutableOverride = ""
    @AppStorage(AIProviderSettings.cliArgumentsKey) private var cliArguments = ""
    @AppStorage(AIProviderSettings.cliModelKey) private var cliModel = ""
    @AppStorage(AIProviderSettings.cliOutputKeyKey) private var cliOutputKey = ""
    @AppStorage(AIProviderSettings.cliTimeoutKey) private var cliTimeout: Double = 120
    @State private var revealKey = false
    @State private var testState: TestState = .idle
    /// Resolved once per edit rather than per redraw — `body` runs often and this hits disk.
    @State private var resolvedCLIPath: String?

    private enum TestState: Equatable {
        case idle, running, ok(String), failed(String)
    }

    private var preset: AIProviderPreset {
        AIProviderPreset(rawValue: presetRaw) ?? .custom
    }

    private var mode: AIServiceMode {
        AIServiceMode(rawValue: modeRaw) ?? .remote
    }

    private var cliPreset: AICLIPreset {
        AICLIPreset(rawValue: cliPresetRaw) ?? .custom
    }

    var body: some View {
        Form {
            Section {
                // Labelled rather than a bare segmented strip: without the label the
                // highlight reads as "the tab you're looking at" when it actually means
                // "the one AI 改写 calls".
                Picker(L10n.tr("settings.aiService.mode"), selection: Binding(
                    get: { mode },
                    set: { modeRaw = $0.rawValue; testState = .idle }
                )) {
                    Text(L10n.tr("settings.aiService.mode.remote")).tag(AIServiceMode.remote)
                    Text(L10n.tr("settings.aiService.mode.local")).tag(AIServiceMode.local)
                }
                .pickerStyle(.segmented)
            }

            if mode == .local {
                localSections
            } else {
                remoteSections
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
        .onAppear { refreshCLIPath() }
        .onChange(of: cliExecutable) { _, _ in refreshCLIPath(); testState = .idle }
        .onChange(of: cliExecutableOverride) { _, _ in refreshCLIPath(); testState = .idle }
    }

    // MARK: - Hosted endpoint

    @ViewBuilder
    private var remoteSections: some View {
        Group {
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
        }
    }

    // MARK: - Local CLI

    @ViewBuilder
    private var localSections: some View {
        Group {
            Section {
                Picker(L10n.tr("settings.aiService.cli.preset"), selection: Binding(
                    get: { cliPreset },
                    set: { applyCLIPreset($0) }
                )) {
                    ForEach(AICLIPreset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                if cliPreset == .custom {
                    customCLIFields
                } else {
                    detectionRow
                    TextField(L10n.tr("settings.aiService.model"), text: $cliModel,
                              prompt: Text(L10n.tr("settings.aiService.cli.model.placeholder")))
                        .autocorrectionDisabled()
                        .onChange(of: cliModel) { _, _ in testState = .idle }
                    // The command line for a known agent is ours to get right, so it stays
                    // hidden — except when we can't find the binary, where the only thing
                    // that helps is the user pointing at it.
                    if resolvedCLIPath == nil {
                        TextField(L10n.tr("settings.aiService.cli.executable"), text: $cliExecutableOverride,
                                  prompt: Text("/usr/local/bin/\(cliPreset.executable)"))
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if cliPreset == .custom {
                        Text(L10n.tr("settings.aiService.cli.argumentsHint", AICLIConfig.promptToken))
                    } else if resolvedCLIPath == nil {
                        Text(L10n.tr("settings.aiService.cli.missingHint", cliPreset.displayName))
                    }
                    Text(L10n.tr("settings.aiService.cli.privacyHint"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Stepper(value: $cliTimeout, in: 30...600, step: 30) {
                    LabeledContent(L10n.tr("settings.aiService.timeout")) {
                        Text(L10n.tr("settings.aiService.timeout.seconds", Int(cliTimeout)))
                    }
                }
            } footer: {
                Text(L10n.tr("settings.aiService.cli.timeoutHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The three knobs behind every preset. Shown only for Custom — for a named agent
    /// these are filled in from the preset and would just be noise.
    @ViewBuilder
    private var customCLIFields: some View {
        TextField(L10n.tr("settings.aiService.cli.executable"), text: $cliExecutable,
                  prompt: Text("claude"))
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
        detectionRow
        TextField(L10n.tr("settings.aiService.cli.arguments"), text: $cliArguments,
                  prompt: Text("-p \(AICLIConfig.promptToken)"))
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
            .onChange(of: cliArguments) { _, _ in testState = .idle }
        TextField(L10n.tr("settings.aiService.cli.outputKey"), text: $cliOutputKey,
                  prompt: Text(L10n.tr("settings.aiService.cli.outputKey.placeholder")))
            .autocorrectionDisabled()
            .font(.system(.body, design: .monospaced))
            .onChange(of: cliOutputKey) { _, _ in testState = .idle }
    }

    /// Whether the command resolves on this Mac — the one thing that can't be told from
    /// the text field, since a GUI app searches different directories than the shell does.
    @ViewBuilder
    private var detectionRow: some View {
        if effectiveExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else if let path = resolvedCLIPath {
            LabeledContent("") {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .labelsHidden()
        } else {
            LabeledContent("") {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    Text(L10n.tr("settings.aiService.cli.notFound"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .labelsHidden()
        }
    }

    /// Records the choice and nothing else. A preset's command line is read from the
    /// preset at call time, so copying it into storage would only risk overwriting a
    /// Custom setup the user comes back to.
    private func applyCLIPreset(_ p: AICLIPreset) {
        cliPresetRaw = p.rawValue
        testState = .idle
        refreshCLIPath()
    }

    /// What `AIProviderSettings.cliSnapshot()` would actually run.
    private var effectiveExecutable: String {
        guard cliPreset != .custom else { return cliExecutable }
        return cliExecutableOverride.isEmpty ? cliPreset.executable : cliExecutableOverride
    }

    private func refreshCLIPath() {
        resolvedCLIPath = CLIResolver.resolve(effectiveExecutable)
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
        let isLocal = mode == .local
        let httpClient = AIClient(config: AIProviderSettings.snapshot())
        let cliBackend = AICLIBackend(config: AIProviderSettings.cliSnapshot())
        Task {
            do {
                let reply = isLocal ? try await cliBackend.testConnection()
                                    : try await httpClient.testConnection()
                testState = .ok(String(reply.prefix(40)))
            } catch let error as AIError {
                testState = .failed(error.userMessage)
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}
