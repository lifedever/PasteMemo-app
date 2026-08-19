import SwiftUI

/// Preview for clips produced by SMSCodeWatcher: the extracted code rendered as
/// OTP-style character cells, the full SMS body in a card below, so the user
/// sees context (sender, validity window) without opening Messages. Shared by
/// QuickPreviewPane and ClipDetailView.
struct SMSCodePreview: View {
    let code: String
    let message: String

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                codeCells
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.tr("sms.preview.messageLabel"), systemImage: "message.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    /// One rounded cell per character; separators (hyphens) render bare so
    /// grouped codes like "RKJ-YP6" read naturally.
    private var codeCells: some View {
        HStack(spacing: 5) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, character in
                if character == "-" {
                    Text("-")
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(character))
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .frame(width: 34, height: 44)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
