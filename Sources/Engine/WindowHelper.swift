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
@MainActor
func showSettingsWindowAppKit() {
    WindowManager.shared.show(
        id: "settings",
        title: L10n.tr("settings.title"),
        size: NSSize(width: 720, height: 470),
        floating: false,
        styleMask: [.titled, .closable, .miniaturizable],
        autoResizesToContent: true
    ) {
        SettingsView()
            .environmentObject(ClipboardManager.shared)
            .modelContainer(PasteMemoApp.sharedModelContainer)
    }
}

/// 自动化管理器窗口。同上,走 AppKit 路径(issue #66)。
@MainActor
func showAutomationManagerWindow() {
    WindowManager.shared.show(
        id: "automationManager",
        title: L10n.tr("automation.window.title"),
        size: NSSize(width: 700, height: 500),
        floating: false,
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        frameAutosaveName: "AutomationManagerWindow"
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
