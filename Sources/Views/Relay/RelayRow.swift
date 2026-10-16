import AppKit
import SwiftUI

/// 单条接力队列的 Row：状态点 · 来源 App 图标 · 内容（可选二级 diff 预览）· current 时的
/// 粘贴后按键 glyph / hover 时的 [✂ 拆分] [🗑 删除] 工具按钮。
struct RelayRow: View {
    let item: RelayItem
    let previewRule: AutomationRule?
    var onDelete: (() -> Void)?
    var onSplit: (() -> Void)?

    @State private var isHovering = false
    @AppStorage(RelayPostPasteKey.userDefaultsKey) private var postPasteKeyRaw = RelayPostPasteKey.none.rawValue

    /// 仅在规则条件匹配时返回 actions（和 `RelayRuleResolver.actionsApplying` 对齐）。
    private var effectivePreviewActions: [RuleAction] {
        guard let rule = previewRule, item.contentKind == .text else { return [] }
        guard item.content.utf8.count <= 64 * 1024 else { return [] }
        return RelayRuleResolver.matches(rule, item: item) ? rule.actions : []
    }

    private var primaryText: String {
        if item.isFile { return item.displayName }
        let cap = 500
        let sample = item.content.count > cap ? String(item.content.prefix(cap)) + "…" : item.content
        return sample.replacingOccurrences(of: "\n", with: " ↵ ")
    }

    private var previewText: String? {
        guard !effectivePreviewActions.isEmpty else { return nil }
        let processed = AutomationEngine.apply(effectivePreviewActions, to: item.content)
        guard processed != item.content else { return nil }
        return processed.replacingOccurrences(of: "\n", with: " ↵ ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            stateIndicator
            sourceAppBadge
            contentColumn
            Spacer(minLength: 0)
            trailingColumn
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(rowBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(item.state == .current ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }

    // MARK: - Subviews

    @ViewBuilder private var stateIndicator: some View {
        switch item.state {
        case .done:
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(.green.opacity(0.8))
        case .current:
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        case .skipped:
            Image(systemName: "circle.slash")
                .font(.system(size: 10))
                .foregroundStyle(.secondary.opacity(0.6))
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 9))
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }

    @ViewBuilder private var sourceAppBadge: some View {
        if let bundleID = item.sourceAppBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 12, height: 12)
                .help(bundleID)
        } else {
            Color.clear.frame(width: 12, height: 12)
        }
    }

    @ViewBuilder private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 13))
                .foregroundStyle(textColor)
                .strikethrough(item.state == .skipped, color: .secondary)
            if let preview = previewText {
                Text("→ " + preview)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var trailingColumn: some View {
        if isHovering {
            HStack(spacing: 6) {
                if !item.isImage, !item.isFile, item.content.count > 1 {
                    Button { onSplit?() } label: {
                        Image(systemName: "scissors").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.tr("relay.split"))
                    .accessibilityLabel(L10n.tr("relay.split"))
                }
                Button { onDelete?() } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.8))
                .help(L10n.tr("relay.delete"))
                .accessibilityLabel(L10n.tr("relay.delete"))
            }
        } else if item.state == .current, let glyph = postPasteKeyGlyph {
            Text(glyph)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private var textColor: Color {
        switch item.state {
        case .done: return .secondary
        case .current: return .primary
        case .skipped: return .secondary.opacity(0.6)
        case .pending: return .primary.opacity(0.85)
        }
    }

    private var rowBackground: Color {
        if item.state == .current {
            return Color.accentColor.opacity(0.12)
        }
        return isHovering ? Color.primary.opacity(0.04) : Color.clear
    }

    private var postPasteKeyGlyph: String? {
        guard let key = RelayPostPasteKey(rawValue: postPasteKeyRaw), key != .none else { return nil }
        switch key {
        case .none: return nil
        case .return: return "⏎"
        case .tab: return "⇥"
        case .space: return "␣"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        }
    }
}
