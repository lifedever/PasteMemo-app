import AppKit
@preconcurrency import UserNotifications

/// 后台发现新版本 / 静默装完新版本时发的系统通知。
///
/// 自动检查以前直接弹更新窗口，窗口是 `.floating` 层级还会
/// `activate(ignoringOtherApps:)`，全屏游戏、全屏视频都会被拉回桌面。现在更新窗口
/// 已经去掉：后台发现新版本只发通知（右上角横幅，专注模式下由系统压住），
/// 点了通知打开设置里的「软件更新」页。
@MainActor
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()

    /// 固定 identifier：同一类通知再发一次会替换旧的，不会在通知中心堆好几条。
    nonisolated static let availableID = "update.available"
    nonisolated static let installedID = "update.installed"

    private override init() { super.init() }

    /// 在 applicationDidFinishLaunching 里调用。之前没有任何地方设过 delegate，
    /// 所以其他通知（验证码、快捷指令）的行为要保持原样，见 `willPresent`。
    func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func notifyAvailable(version: String, notes: String?) {
        post(
            id: Self.availableID,
            title: L10n.tr("update.notify.available.title", version),
            body: Self.plainNotes(notes)
        )
    }

    func notifyInstalled(version: String, notes: String?) {
        // 新版本已经装上，「发现新版本」那条留着只会误导
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.availableID])
        post(
            id: Self.installedID,
            title: L10n.tr("update.notify.installed.title", version),
            body: Self.plainNotes(notes)
        )
    }

    /// release notes 是 markdown（`- **新增** xxx`），通知里只能放纯文本。
    /// 去掉标题行、列表符号和加粗，剩下的交给系统截断。
    nonisolated static func plainNotes(_ markdown: String?) -> String {
        guard let markdown else { return "" }
        return markdown
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                var text = line
                if text.hasPrefix("- ") || text.hasPrefix("* ") { text.removeFirst(2) }
                return text.replacingOccurrences(of: "**", with: "")
            }
            .joined(separator: "\n")
    }

    // MARK: - Delivery

    /// 先查授权 → 未决定时请求 → 授权后再 add（和 ShortcutRunner.deliver 一样，
    /// request 和 add 并行会丢第一条）。拒绝了就算了：状态栏图标上的小圆点还在。
    private func post(id: String, title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request)
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { center.add(request) }
                }
            default:
                DiagnosticLog.log("UPDATE notification not authorized; id=\(id)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        if id == Self.availableID {
            Task { @MainActor in
                // 通知中心里的旧通知（App 重启过、或已经更新过）：到页面上现查一次
                showUpdatePage(check: !UpdateChecker.shared.updateAvailable)
            }
        }
        completionHandler()
    }

    /// App 在前台时系统会先问这里要不要显示。没设 delegate 时默认是不显示，
    /// 验证码、快捷指令那几条通知一直是这个行为，保持不变；只放行更新通知。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let id = notification.request.identifier
        let isUpdate = id == Self.availableID || id == Self.installedID
        completionHandler(isUpdate ? [.banner, .list] : [])
    }
}

// MARK: - Idle install gate

/// 「自动安装更新」什么时候可以动手：装的时候 PasteMemo 要退出重启，所以只挑用户
/// 不在用电脑、也不在用 PasteMemo 的时候。
enum AutoInstallGate {
    /// 键鼠闲置多久才装。看全屏视频时没有输入也会满足——装的过程不弹窗、
    /// 重启用 `open -g` 不抢前台，对视频没影响。
    static let requiredIdleSeconds: TimeInterval = 10 * 60

    /// 每隔多久看一次闲置状态
    static let pollInterval: TimeInterval = 60

    static func isReady(
        idleSeconds: TimeInterval,
        appIsActive: Bool,
        relayActive: Bool,
        hasOpenWorkWindow: Bool
    ) -> Bool {
        idleSeconds >= requiredIdleSeconds
            && !appIsActive
            && !relayActive
            && !hasOpenWorkWindow
    }

    /// 距离最后一次键盘 / 鼠标 / 触控板输入过了多少秒（任意输入事件 = ~0）。
    static func systemIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
