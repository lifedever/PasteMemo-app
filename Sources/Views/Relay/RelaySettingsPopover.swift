import SwiftUI
import SwiftData

struct RelaySettingsPopover: View {
    @AppStorage("relayPasteAsPlainText") private var pasteAsPlainText = false
    @AppStorage("relayAllowRepeatCopy") private var allowRepeatCopy = false
    @AppStorage(RelayPostPasteKey.userDefaultsKey) private var postPasteKeyRaw = RelayPostPasteKey.none.rawValue
    @AppStorage("relayAutomationRuleId") private var automationRuleId = ""
    @AppStorage("relayPreviewEnabled") private var previewEnabled = false
    @AppStorage("relayCompleteSoundName") private var completeSoundName: String = "Pop"

    @Query(
        filter: #Predicate<AutomationRule> { $0.enabled == true },
        sort: \AutomationRule.sortOrder
    ) private var enabledRules: [AutomationRule]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingRow(
                title: L10n.tr("relay.settings.plainText"),
                subtitle: L10n.tr("relay.settings.plainText.desc")
            ) {
                Toggle("", isOn: $pasteAsPlainText)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(width: 140, alignment: .trailing)
            }

            Divider().padding(.leading, 12)

            settingRow(
                title: L10n.tr("relay.settings.allowRepeatCopy"),
                subtitle: L10n.tr("relay.settings.allowRepeatCopy.desc")
            ) {
                Toggle("", isOn: $allowRepeatCopy)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(width: 140, alignment: .trailing)
            }

            Divider().padding(.leading, 12)

            settingRow(
                title: L10n.tr("relay.settings.automation"),
                subtitle: L10n.tr("relay.settings.automation.desc")
            ) {
                Picker("", selection: $automationRuleId) {
                    Text(L10n.tr("relay.settings.automation.none")).tag("")
                    ForEach(enabledRules) { rule in
                        Text(ruleDisplayName(rule)).tag(rule.ruleID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 140, alignment: .trailing)
            }

            Divider().padding(.leading, 12)

            settingRow(
                title: L10n.tr("relay.settings.preview"),
                subtitle: L10n.tr("relay.settings.preview.desc")
            ) {
                Toggle("", isOn: $previewEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(automationRuleId.isEmpty)
                    .frame(width: 140, alignment: .trailing)
            }

            Divider().padding(.leading, 12)

            settingRow(
                title: L10n.tr("relay.settings.completeSound"),
                subtitle: L10n.tr("relay.settings.completeSound.desc")
            ) {
                Picker("", selection: $completeSoundName) {
                    Text(L10n.tr("relay.settings.completeSound.mute")).tag("")
                    ForEach(SoundManager.relayCompleteSoundOptions.filter { !$0.isEmpty }, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 140, alignment: .trailing)
                // Preview the sound the user just chose so they can compare options.
                .onChange(of: completeSoundName) { _, newValue in
                    SoundManager.previewRelayCompleteSound(newValue)
                }
            }

            Divider().padding(.leading, 12)

            settingRow(
                title: L10n.tr("relay.settings.postPasteKey"),
                subtitle: L10n.tr("relay.settings.postPasteKey.desc")
            ) {
                Picker("", selection: $postPasteKeyRaw) {
                    ForEach(RelayPostPasteKey.allCases, id: \.rawValue) { key in
                        Text(displayName(for: key)).tag(key.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 140, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 300)
    }

    private func settingRow<Control: View>(
        title: String,
        subtitle: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func ruleDisplayName(_ rule: AutomationRule) -> String {
        // Built-in rules use L10n keys (e.g. "automation.builtIn.cleanTracking")
        // as their name. Custom rules use literal names typed by the user.
        let translated = L10n.tr(rule.name)
        return translated == rule.name && rule.name.hasPrefix("automation.") ? rule.name : translated
    }

    private func displayName(for key: RelayPostPasteKey) -> String {
        switch key {
        case .none: return L10n.tr("relay.settings.postPasteKey.none")
        case .return: return "⏎  " + L10n.tr("relay.settings.postPasteKey.return")
        case .tab: return "⇥  " + L10n.tr("relay.settings.postPasteKey.tab")
        case .space: return "␣  " + L10n.tr("relay.settings.postPasteKey.space")
        case .up: return "↑  " + L10n.tr("relay.settings.postPasteKey.up")
        case .down: return "↓  " + L10n.tr("relay.settings.postPasteKey.down")
        case .left: return "←  " + L10n.tr("relay.settings.postPasteKey.left")
        case .right: return "→  " + L10n.tr("relay.settings.postPasteKey.right")
        }
    }
}
