import SwiftUI

// Chrome shared by the quick panel and the windows built like it (the standalone split
// window): the footer's key labels, its glass capsule, the hover state of clickable keys.

/// macOS 14/15 下图标按钮的 hover 高亮（26 上走 .buttonStyle(.glass)）。
/// 刻意只给真正可点的按钮加——footerKey 是纯展示的键位提示，给它加 hover 态
/// 会让用户以为能点。
struct HoverHighlight: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovering ? 0.09 : 0))
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// 玻璃表面。macOS 26 用官方 `.glassEffect()`，旧系统降级到 material + 描边。
/// 刻意不再手绘「实底 + 阴影」去模拟玻璃——那套只是长得像，系统一升级就漂移，
/// 深浅色和外观切换还全得自己维护。
struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
        }
    }
}

/// A key hint in the footer capsule: the key in a small rounded box, then what it does.
struct FooterKeyLabel: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            // 和 ⌘K 卡片里的键位标签同一套画法：独立圆角小方块 + 细描边
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(minWidth: 22, minHeight: 22)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
            Text(label)
                .font(.system(size: 11))
                // 说明文字是主信息，走 primary；键位标记退到 secondary 做层级
                // （参考 Raycast 底栏：文字近黑、键帽偏灰）。之前 .tertiary 在玻璃上几乎看不清。
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Title row of a page that takes over the panel (⌘E edit, split): a symbol and the
/// page's name where the search field was. Same height and margins as the search row,
/// so nothing below jumps when the page opens or closes.
struct PageHeader: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(height: 28)
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }
}

/// The footer capsule's keys while the split page is open. Its own view so the
/// 「拆成 N 条」count follows the ticks without the whole panel observing the session.
struct SplitFooterKeys: View {
    @ObservedObject var session: SplitSession
    /// The Relay queue's own split has nowhere further to send the pieces.
    var showsRelay = true
    let onConfirm: () -> Void
    let onRelay: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Button(action: onConfirm) {
            FooterKeyLabel(
                key: "⌘↵",
                label: session.canConfirm
                    ? L10n.tr("split.confirm", session.chosenPieces.count)
                    : L10n.tr("action.split")
            )
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .pointerCursor()
        .disabled(!session.canConfirm)

        if showsRelay, !session.isFiles {
            Button(action: onRelay) {
                FooterKeyLabel(key: "⌘R", label: L10n.tr("relay.startRelay"))
            }
            .buttonStyle(.plain)
            .modifier(HoverHighlight())
            .pointerCursor()
            .disabled(!session.canConfirm)
        }

        Button(action: onCancel) {
            FooterKeyLabel(key: "esc", label: L10n.tr("action.cancel"))
        }
        .buttonStyle(.plain)
        .modifier(HoverHighlight())
        .pointerCursor()
    }
}
