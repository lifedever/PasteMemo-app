import AppKit
import SwiftData
import SwiftUI

/// 紧凑态永久可见的 Hero 分区：计数 + 规则 pill + 齿轮 / 当前内容 + 预览 diff /
/// 进度色块 / 上一条·跳过 / 循环·结束后自动退出 / 暂停·退出·清空退出 + 抽屉把手。
struct RelayHeroCard: View {
    @Bindable var manager: RelayManager
    @Binding var drawerOpen: Bool
    @State private var showSettingsPopover = false
    @AppStorage("relayAutomationRuleId") private var settingAutomationRuleId = ""
    @AppStorage("relayPreviewEnabled") private var settingPreviewEnabled = false
    @AppStorage("relayLoopEnabled") private var settingLoopEnabled = false
    @Query(filter: #Predicate<AutomationRule> { $0.enabled == true })
    private var enabledRules: [AutomationRule]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.3)
            currentContent
            progressBar
            mainActions
            Divider().opacity(0.3)
            modeRow
            Divider().opacity(0.3)
            bottomBar
        }
    }

    // MARK: - Top bar (count + rule pill + settings)

    private var topBar: some View {
        HStack(spacing: 6) {
            Text(manager.progressText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            if let rule = activeRule {
                rulePill(rule)
            } else {
                Color.clear.frame(height: 16)
                Spacer()
            }
            Button { showSettingsPopover.toggle() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettingsPopover, arrowEdge: .top) {
                RelaySettingsPopover()
                    .modelContainer(PasteMemoApp.sharedModelContainer)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(WindowDragArea())
    }

    private var activeRule: AutomationRule? {
        guard !settingAutomationRuleId.isEmpty else { return nil }
        return enabledRules.first { $0.ruleID == settingAutomationRuleId }
    }

    private func rulePill(_ rule: AutomationRule) -> some View {
        Button {
            settingAutomationRuleId = ""
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").font(.system(size: 10))
                Text(ruleDisplayName(rule)).font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if settingPreviewEnabled {
                    Text("· " + L10n.tr("relay.settings.preview"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.tr("relay.banner.clickToClear"))
        .contextMenu {
            ForEach(enabledRules) { r in
                Button {
                    settingAutomationRuleId = r.ruleID
                } label: {
                    if r.ruleID == settingAutomationRuleId {
                        Label(ruleDisplayName(r), systemImage: "checkmark")
                    } else {
                        Text(ruleDisplayName(r))
                    }
                }
            }
        }
    }

    // MARK: - Current content

    @ViewBuilder private var currentContent: some View {
        if let item = manager.currentItem {
            VStack(alignment: .leading, spacing: 6) {
                sourceBadge(for: item)
                Text(item.isFile ? item.displayName : item.content)
                    .font(.system(size: 14))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if let preview = previewDiff(for: item) {
                    Text("→ " + preview)
                        .font(.system(size: 12))
                        .foregroundStyle(.green.opacity(0.85))
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.green.opacity(0.08))
                        )
                        .overlay(
                            Rectangle()
                                .fill(Color.green.opacity(0.4))
                                .frame(width: 2),
                            alignment: .leading
                        )
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else {
            RelayEmptyState()
        }
    }

    @ViewBuilder private func sourceBadge(for item: RelayItem) -> some View {
        if let bundleID = item.sourceAppBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            HStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 11, height: 11)
                Text(FileManager.default.displayName(atPath: url.path))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func previewDiff(for item: RelayItem) -> String? {
        guard let rule = activeRule, settingPreviewEnabled, item.contentKind == .text else { return nil }
        let contentType = ClipboardManager.shared.detectContentType(item.content).type
        let ok = rule.conditions.isEmpty || AutomationEngine.matchesConditions(
            rule.conditions,
            logic: rule.conditionLogic,
            content: item.content,
            contentType: contentType,
            sourceApp: item.sourceAppBundleID
        )
        guard ok else { return nil }
        let processed = AutomationEngine.apply(rule.actions, to: item.content)
        return processed == item.content ? nil : processed
    }

    // MARK: - Progress bar (color blocks)

    @ViewBuilder private var progressBar: some View {
        if !manager.items.isEmpty {
            HStack(spacing: 3) {
                ForEach(Array(manager.items.enumerated()), id: \.element.id) { _, item in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: item))
                        .frame(height: 3)
                        .help(item.isFile ? item.displayName : String(item.content.prefix(60)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private func color(for item: RelayItem) -> Color {
        switch item.state {
        case .done: return .green.opacity(0.5)
        case .current: return Color.accentColor
        case .skipped: return .secondary.opacity(0.3)
        case .pending: return .secondary.opacity(0.15)
        }
    }

    // MARK: - Main actions (prev / skip)

    @ViewBuilder private var mainActions: some View {
        HStack(spacing: 8) {
            Button { manager.rollback() } label: {
                Label(L10n.tr("relay.previous"), systemImage: "chevron.left")
                    .font(.system(size: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(manager.currentIndex == 0)
            .opacity(manager.currentIndex == 0 ? 0.4 : 0.8)

            Spacer()

            Button { manager.skip() } label: {
                HStack(spacing: 3) {
                    Text(L10n.tr("relay.skip"))
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.2), in: Capsule())
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(manager.isQueueExhausted)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Mode row

    private var modeRow: some View {
        HStack(spacing: 10) {
            Button {
                settingLoopEnabled.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                    Text(L10n.tr("relay.loop"))
                        .font(.system(size: 11))
                }
                .foregroundStyle(settingLoopEnabled ? Color.accentColor : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    (settingLoopEnabled ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05)),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .help(L10n.tr("relay.loop"))

            Toggle(isOn: $manager.autoExitOnEmpty) {
                Text(L10n.tr("relay.autoExit.short"))
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 6) {
            pillButton(
                icon: manager.isPaused ? "play.fill" : "pause.fill",
                title: manager.isPaused ? L10n.tr("relay.resume") : L10n.tr("relay.pause"),
                tint: manager.isPaused ? .green : .secondary
            ) {
                if manager.isPaused { manager.resume() } else { manager.pause() }
            }

            pillButton(icon: "xmark", title: L10n.tr("relay.exit"), tint: .secondary) {
                manager.deactivate()
            }

            pillButton(icon: "trash", title: L10n.tr("relay.clearAndExit"), tint: .red) {
                manager.deactivate(clearQueue: true)
            }
            .disabled(manager.items.isEmpty)

            Spacer()

            Button {
                drawerOpen.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: drawerOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                    Text(drawerOpen ? L10n.tr("relay.collapse") : L10n.tr("relay.expand"))
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(drawerOpen ? L10n.tr("relay.collapse") : L10n.tr("relay.expand"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func pillButton(icon: String, title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func ruleDisplayName(_ rule: AutomationRule) -> String {
        let translated = L10n.tr(rule.name)
        return translated == rule.name && rule.name.hasPrefix("automation.") ? rule.name : translated
    }
}
