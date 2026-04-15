import SwiftUI

struct RelaySettingsPopover: View {
    @AppStorage("relayPasteAsPlainText") private var pasteAsPlainText = false
    @AppStorage(RelayPostPasteKey.userDefaultsKey) private var postPasteKeyRaw = RelayPostPasteKey.none.rawValue

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
                .frame(width: 110)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 280)
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

    private func displayName(for key: RelayPostPasteKey) -> String {
        switch key {
        case .none: return L10n.tr("relay.settings.postPasteKey.none")
        case .return: return L10n.tr("relay.settings.postPasteKey.return")
        case .tab: return L10n.tr("relay.settings.postPasteKey.tab")
        case .down: return L10n.tr("relay.settings.postPasteKey.down")
        case .space: return L10n.tr("relay.settings.postPasteKey.space")
        }
    }
}
