import SwiftUI

/// 条目文字的编辑框：主窗口详情和快捷面板共用。带富文本格式的条目在上方提示
/// 「保存后转为纯文本」——保存走 `ClipboardManager.applyEditedContent`，格式存不下来。
struct ClipTextEditor: View {
    let hasRichText: Bool
    let text: String
    var fontSize: CGFloat = 13
    let onTextChange: (String) -> Void
    let onEscape: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasRichText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(L10n.tr("detail.richText.editWarning"))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.08))
                )
            }
            NativeTextView(
                text: text,
                isEditable: true,
                autoFocus: true,
                fontSize: fontSize,
                onTextChange: onTextChange,
                onEscape: onEscape
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.08))
            )
        }
    }
}
