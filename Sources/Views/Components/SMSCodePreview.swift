import SwiftUI

/// Preview for clips produced by SMSCodeWatcher: the extracted code up top, the
/// full SMS body below, so the user sees context (sender, validity window)
/// without opening Messages. Shared by QuickPreviewPane and ClipDetailView.
struct SMSCodePreview: View {
    let code: String
    let message: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(code)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Divider()
                Label(L10n.tr("sms.preview.messageLabel"), systemImage: "message")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
