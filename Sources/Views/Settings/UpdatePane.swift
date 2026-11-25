import SwiftUI

/// 设置 →「软件更新」。更新的全部交互都在这一页：当前状态、更新内容、下载进度、
/// 出错原因、相关设置。以前单独弹的更新窗口会抢前台（全屏游戏、视频都被拉回桌面），已去掉。
struct UpdatePane: View {
    @ObservedObject private var updater = UpdateChecker.shared
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @AppStorage("updateCheckInterval") private var updateCheckInterval = UpdateChecker.defaultCheckIntervalHours
    @AppStorage("includeBetaChannel") private var includeBetaChannel = false
    @AppStorage(UpdateChecker.autoInstallKey) private var autoInstallUpdates = false

    private static let releasesURL = URL(string: "https://github.com/lifedever/PasteMemo-app/releases")!

    /// 有一个比当前新的版本在等着装（含下载中、已下好）
    private var hasPendingUpdate: Bool {
        updater.updateAvailable || updater.isDownloading || updater.downloadComplete
    }

    var body: some View {
        Form {
            Section {
                statusRow
                if let issue = updater.lastIssue {
                    issueRow(issue)
                }
            }

            if hasPendingUpdate, let notes = updater.releaseNotes, !notes.isEmpty {
                Section(L10n.tr("update.section.notes")) {
                    if updater.isBetaUpdate {
                        betaWarning
                    }
                    ReleaseNotesView(markdown: notes)
                }
            }

            Section {
                preferences
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if hasPendingUpdate && updater.isBetaUpdate {
                        betaBadge
                    }
                }
                subtitle
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if hasPendingUpdate, let version = updater.latestVersion {
            return L10n.tr("update.notify.available.title", version)
        }
        if updater.isChecking {
            return L10n.tr("update.status.checking")
        }
        // 刚检查失败时不能还说「已是最新」
        if updater.lastCheckedAt != nil, updater.lastIssue != .checkFailed {
            return L10n.tr("update.status.upToDate")
        }
        return "PasteMemo"
    }

    @ViewBuilder
    private var subtitle: some View {
        if updater.isDownloading {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: updater.downloadProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 240)
                if updater.totalBytes > 0 {
                    Text("\(formatBytes(updater.downloadedBytes)) / \(formatBytes(updater.totalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } else {
            Text(subtitleText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitleText: String {
        if updater.downloadComplete {
            let auto = autoCheckUpdates && autoInstallUpdates
            return L10n.tr(auto ? "update.status.downloaded.auto" : "update.status.downloaded")
        }
        let current = L10n.tr("update.status.currentVersion", updater.currentVersion)
        guard !hasPendingUpdate, !updater.isChecking, let checked = updater.lastCheckedAt else {
            return current
        }
        let style = Date.RelativeFormatStyle(presentation: .named)
            .locale(Locale(identifier: LanguageManager.shared.current))
        return current + " · " + L10n.tr("update.status.lastChecked", checked.formatted(style))
    }

    @ViewBuilder
    private var actions: some View {
        if updater.isChecking {
            ProgressView().controlSize(.small)
        } else if updater.isDownloading {
            Button(L10n.tr("update.cancel")) { updater.cancelDownload() }
                .pointerCursor()
        } else if updater.downloadComplete {
            Button(L10n.tr("update.install_restart")) { updater.installAndRestart() }
                .buttonStyle(.borderedProminent)
                .pointerCursor()
        } else if updater.updateAvailable, let version = updater.latestVersion {
            HStack(spacing: 8) {
                Button(L10n.tr("update.skip")) { updater.skipVersion(version) }
                    .pointerCursor()
                Button(L10n.tr("update.install")) { updater.downloadUpdate() }
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
            }
        } else {
            Button(L10n.tr("update.check")) {
                Task { await updater.checkForUpdates(userInitiated: true) }
            }
            .pointerCursor()
        }
    }

    // MARK: - Issue

    private func issueRow(_ issue: UpdateIssue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(issueTitle(issue))
                    .font(.callout.weight(.medium))
                if let message = issueMessage(issue) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            // 网络问题时给个手动下载的出口；包坏了重新下就行
            if issue != .installFailed {
                Link(L10n.tr("update.check_failed.github"), destination: Self.releasesURL)
            }
        }
    }

    private func issueTitle(_ issue: UpdateIssue) -> String {
        switch issue {
        case .checkFailed: return L10n.tr("update.check_failed")
        case .downloadFailed: return L10n.tr("update.download_error")
        case .installFailed: return L10n.tr("update.dmg_error")
        }
    }

    private func issueMessage(_ issue: UpdateIssue) -> String? {
        switch issue {
        case .checkFailed: return nil
        case .downloadFailed(let message): return message
        case .installFailed: return L10n.tr("update.dmg_error.message")
        }
    }

    // MARK: - Beta

    private var betaBadge: some View {
        Text("BETA")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var betaWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(L10n.tr("update.beta.warning"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Preferences

    @ViewBuilder
    private var preferences: some View {
        Toggle(L10n.tr("settings.autoCheckUpdates"), isOn: $autoCheckUpdates)
            .onChange(of: autoCheckUpdates) {
                if autoCheckUpdates {
                    updater.startPeriodicChecks()
                } else {
                    updater.stopPeriodicChecks()
                }
                // 自动安装跟着自动检查走：重新打开时，已下好的包要重新排上闲置安装
                updater.autoInstallSettingChanged()
            }
        if autoCheckUpdates {
            Picker(L10n.tr("settings.updateCheckInterval"), selection: $updateCheckInterval) {
                Text(L10n.tr("settings.updateCheckInterval.6h")).tag(6)
                Text(L10n.tr("settings.updateCheckInterval.12h")).tag(12)
                Text(L10n.tr("settings.updateCheckInterval.24h")).tag(24)
                Text(L10n.tr("settings.updateCheckInterval.72h")).tag(72)
            }
            .onChange(of: updateCheckInterval) {
                updater.startPeriodicChecks()
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(L10n.tr("settings.autoInstallUpdates"), isOn: $autoInstallUpdates)
                    .onChange(of: autoInstallUpdates) {
                        updater.autoInstallSettingChanged()
                    }
                Text(L10n.tr("settings.autoInstallUpdates.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L10n.tr("settings.includeBetaChannel"), isOn: $includeBetaChannel)
                .onChange(of: includeBetaChannel) {
                    // 切换通道马上查一次，结果就显示在本页上
                    Task { await updater.checkForUpdates(userInitiated: true) }
                }
            Text(L10n.tr("settings.includeBetaChannel.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Release notes

/// 把 release notes 的 markdown（`- **新增** xxx`）画成原生文字：列表项带悬挂缩进，
/// 加粗和链接保留，跟着设置页一起滚。
private struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(ReleaseNotesLine.parse(markdown).enumerated()), id: \.offset) { _, line in
                switch line.kind {
                case .heading:
                    Text(line.text).font(.callout.weight(.semibold))
                case .bullet:
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(line.text)
                    }
                case .text:
                    Text(line.text)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

struct ReleaseNotesLine: Equatable {
    enum Kind: Equatable { case heading, bullet, text }

    let kind: Kind
    let text: AttributedString

    /// 一行一条；标题去掉 `#`，列表项去掉 `- ` / `* `，行内的加粗、链接按 markdown 解析。
    static func parse(_ markdown: String) -> [ReleaseNotesLine] {
        markdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                if line.hasPrefix("#") {
                    let body = String(line.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                    return ReleaseNotesLine(kind: .heading, text: inline(body))
                }
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    return ReleaseNotesLine(kind: .bullet, text: inline(String(line.dropFirst(2))))
                }
                return ReleaseNotesLine(kind: .text, text: inline(line))
            }
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
