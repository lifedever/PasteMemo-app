import Foundation
import AppKit
import SwiftUI

/// 主管理器窗口。不用 SwiftUI `Window` scene:登录自启时 App 在后台启动,SwiftUI
/// 不创建任何窗口,依赖视图 onAppear 注册的 openWindow 闭包永远不会注册,状态栏
/// 「管理器/设置」点击全是 nil?() 空操作(issue #66)。改走 AppKit WindowManager,
/// 跟 onboarding / 更新窗口同一套路径,启动方式不影响可用性。
@MainActor
func showMainManagerWindow() {
    WindowManager.shared.show(
        id: "main",
        title: L10n.tr("app.name"),
        size: NSSize(width: 900, height: 560),
        floating: UserDefaults.standard.bool(forKey: "alwaysOnTop"),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        frameAutosaveName: "MainManagerWindow",
        bridgeToolbar: true
    ) {
        MainWindowView()
            .environmentObject(ClipboardManager.shared)
            .modelContainer(PasteMemoApp.sharedModelContainer)
    }
}

/// 设置窗口。macOS 14+ 对 SwiftUI `Settings` scene 的程序化打开已不可靠:
/// `sendAction(showSettingsWindow:)` 返回 true 但窗口根本不创建(本机诊断日志实证,
/// Apple 自 Sonoma 起收紧为只认 SettingsLink)。设置窗口同样改走 AppKit WindowManager;
/// 系统菜单的「设置…」(Cmd+,)由 CommandGroup(replacing: .appSettings) 指到同一入口。issue #66。
/// 设置窗口侧边栏改成固定宽度之前，AppKit 会把用户拖出来的宽度存进
/// 「NSSplitView Subview Frames …」。恢复那份 frame 时它不校验 SwiftUI 给的
/// min/ideal，于是老用户无论版本怎么更新，侧边栏都停在当年那个宽度上（本机实测存
/// 的是 196pt，比当时的 min 200 还窄）。清一次，之后固定宽度不会再写回去。
private func clearLegacySettingsSidebarWidth() {
    let flag = "settingsSidebarWidthResetDone"
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: flag) else { return }
    for key in defaults.dictionaryRepresentation().keys
    where key.hasPrefix("NSSplitView Subview Frames") && key.contains("Settings") {
        defaults.removeObject(forKey: key)
    }
    defaults.set(true, forKey: flag)
}

@MainActor
func showSettingsWindowAppKit() {
    clearLegacySettingsSidebarWidth()
    let model = SettingsNavigationModel()
    model.onSelectionChange = { category in
        WindowManager.shared.setTitle(L10n.tr(category.titleKey), for: "settings")
    }
    let controller = SettingsSplitViewController(model: model, sidebarWidth: SETTINGS_SIDEBAR_WIDTH)
    WindowManager.shared.showController(
        id: "settings",
        title: L10n.tr(model.selection.titleKey),
        size: NSSize(width: 760, height: 520),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        frameAutosaveName: "SettingsWindow",
        controller: controller,
        beforeShow: { controller.installToolbar(on: $0) }
    )
}

/// 设置窗口侧边栏宽度。照系统设置量的——中文分类名加上图标块和缩进，短于这个数就开始挤。
let SETTINGS_SIDEBAR_WIDTH: CGFloat = 220

/// 自动化管理器窗口。同上,走 AppKit 路径(issue #66)。
@MainActor
func showAutomationManagerWindow() {
    WindowManager.shared.show(
        id: "automationManager",
        title: L10n.tr("automation.window.title"),
        size: NSSize(width: 700, height: 500),
        floating: false,
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        frameAutosaveName: "AutomationManagerWindow",
        // 同主管理器:NavigationSplitView 侧边栏要通顶需要 fullSizeContentView,
        // 由 bridgeToolbar 一并补上(否则侧边栏从标题栏下方才开始,顶部断一截)。
        bridgeToolbar: true
    ) {
        AutomationManagerView()
            .modelContainer(PasteMemoApp.sharedModelContainer)
    }
}

@MainActor
func showOnboardingWindow() {
    WindowManager.shared.show(
        id: "onboarding",
        title: L10n.tr("onboarding.welcome.title"),
        size: NSSize(width: 480, height: 380),
        floating: false,
        content: { OnboardingView() },
        onClose: { HotkeyManager.shared.register() }
    )
}

@MainActor
func showHelpWindow() {
    if let url = URL(string: "https://www.lifedever.com/PasteMemo/help/") {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
func showHomePage() {
    if let url = URL(string: "https://www.lifedever.com/PasteMemo/") {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
func showAccessibilityPrompt() {
    let alert = NSAlert()
    alert.messageText = L10n.tr("accessibility.lost.title")
    alert.informativeText = L10n.tr("accessibility.lost.message")
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.tr("onboarding.accessibility.grant"))
    alert.addButton(withTitle: L10n.tr("accessibility.lost.later"))

    // The bundle-missing fallback lives inside `openAccessibilitySettings`
    // itself so every entry point (this alert, the menu bar item, the
    // onboarding screen) is covered by a single guard. (issue #38)
    if alert.runModal() == .alertFirstButtonReturn {
        AccessibilityMonitor.shared.openAccessibilitySettings()
    }
}

@MainActor
func showUpdateWindow(updater: UpdateChecker) {
    WindowManager.shared.show(
        id: "update",
        title: L10n.tr("update.available.title"),
        size: NSSize(width: 520, height: 460)
    ) {
        UpdateDialogView(updater: updater)
    }
}
