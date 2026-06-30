import AppKit
import SwiftUI
import Darwin

// MARK: - Bridge for SwiftUI → AppKit window actions

@MainActor
final class AppAction {
    static let shared = AppAction()
    var openMainWindow: (() -> Void)?
    var openSettings: (() -> Void)?
    var openAutomationManager: (() -> Void)?
    private init() {}
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shouldReallyQuit = false
    private var isLaunchComplete = false

    override init() {
        super.init()
        NSApp?.setActivationPolicy(.accessory)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 全局忽略 SIGPIPE。MCPSocketServer 给 AI Agent 客户端回包时,若对端(MCP
        // helper / Claude)已断开,往那个 Unix socket send() 默认会触发 SIGPIPE,而
        // 它的默认处置是「直接终止整个进程」—— 表现为 App「莫名其妙退出」且不留任何
        // crash report(SIGPIPE 不生成崩溃报告)。忽略后 send()/write() 改为返回 -1
        // 并置 errno=EPIPE(调用处本就丢弃返回值,无害),进程不再被杀。这是任何做
        // socket/pipe IO 的 App 的标准防护;配合 MCPSocketServer 里 client fd 上的
        // SO_NOSIGPIPE 双保险。放在最早的统一启动点,任何启动方式都先于 socket IO 跑到。
        signal(SIGPIPE, SIG_IGN)

        let mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
        AppDelegate.applyAppearance(mode)

        // 诊断日志(issue #66 「一段时间后打不开设置」)：先自检,确认日志通道可用。
        let healthy = DiagnosticLog.runSelfCheck()
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        DiagnosticLog.log("LAUNCH dev=\(DevDataImporter.isDevBuild) macOS=\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion) selfCheckHealthy=\(healthy)")
        registerDiagnosticObservers()

        ClipboardManager.shared.modelContainer = PasteMemoApp.sharedModelContainer
        OCRTaskCoordinator.shared.configure(modelContainer: PasteMemoApp.sharedModelContainer)
        // GC orphaned original-image cache files (deleted/expired clips, crash orphans).
        // Runs before monitoring starts so a fresh copy can't be mistaken for an orphan.
        ClipboardManager.sweepOrphanedOriginalImageCacheFiles(in: PasteMemoApp.sharedModelContainer.mainContext)
        if ProManager.AUTOMATION_ENABLED {
            BuiltInRules.seedIfNeeded(context: PasteMemoApp.sharedModelContainer.mainContext)
        }
        if ClipboardManager.shared.isMonitoringEnabled {
            ClipboardManager.shared.startMonitoring()
        }
        UsageTracker.pingIfNeeded()

        // 三个开窗闭包必须在这里注册(applicationDidFinishLaunching 任何启动方式都
        // 必跑),不能放在视图 onAppear:登录自启时 App 在后台启动,SwiftUI 不创建
        // 任何窗口,onAppear 永远不执行,闭包保持 nil → 状态栏「管理器/设置」点击
        // 静默无效,直到手动重启 App(issue #66,本机日志坐实)。
        registerAppActions()
        isLaunchComplete = true

        // 自定义状态栏图标（支持左/右键不同动作）—— 取代原来的 MenuBarExtra(.menu)。
        StatusBarController.shared.install()

        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        let needsAccessibility = !AXIsProcessTrusted()

        HotkeyManager.shared.register()

        // Wire Relay Mode protocols
        RelayManager.shared.clipboardController = ClipboardManager.shared
        RelayManager.shared.hotkeyController = HotkeyManager.shared

        if !hasCompletedOnboarding {
            let hideDock = UserDefaults.standard.bool(forKey: "hideDockIcon")
            if !hideDock {
                NSApp.setActivationPolicy(.regular)
            }
            showOnboardingWindow()
        } else if needsAccessibility {
            let hideDock = UserDefaults.standard.bool(forKey: "hideDockIcon")
            if !hideDock {
                NSApp.setActivationPolicy(.regular)
            }
            showAccessibilityPrompt()
        }

        Task {
            await UpdateChecker.shared.checkForUpdates()
            UpdateChecker.shared.startPeriodicChecks()
        }

        BackupScheduler.shared.start(container: PasteMemoApp.sharedModelContainer)
        SyncScheduler.shared.start(container: PasteMemoApp.sharedModelContainer)

        // 总开关:默认值由 PasteMemoApp.migrateMCPEnabledIfNeeded() 决定 ——
        // 1.7.x 升级用户 = true (保持原行为),全新安装 = false (隐私优先)。issue #50
        if UserDefaults.standard.bool(forKey: "mcpEnabled") {
            MCPSocketServer.shared.start(container: PasteMemoApp.sharedModelContainer)
        }

        // 已主动安装过 Claude Skill 的用户,App 升级后静默把 SKILL.md 同步到最新模板
        // (仅当本地未被用户改过时)。从未安装 / 改过 / 删过的用户都不会被打扰。
        MCPAgentRegistry.syncSkillsIfNeeded()

        // Pre-warm quick panel as soon as launch setup settles so the first open is faster.
        DispatchQueue.main.async {
            QuickPanelWindowController.shared.warmUp(
                clipboardManager: ClipboardManager.shared,
                modelContainer: PasteMemoApp.sharedModelContainer
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BackupScheduler.shared.stop()
        SyncScheduler.shared.stop()
        MCPSocketServer.shared.stop()
        // Persist relay queue synchronously before termination — otherwise in-memory
        // items never reach disk when the user quits while a relay session is active.
        if RelayManager.shared.isActive {
            RelayManager.shared.deactivate()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppDelegate.shouldReallyQuit else {
            hideAllMainWindows(sender)
            NSApp.setActivationPolicy(.accessory)
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        AppAction.shared.openMainWindow?()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if isLaunchComplete {
            NSApp.setActivationPolicy(.accessory)
        }
        return false
    }

    // MARK: - Window actions (issue #66)

    /// 全部走 AppKit 路径,不依赖任何 SwiftUI 场景/视图先出现。
    private func registerAppActions() {
        AppAction.shared.openMainWindow = {
            DiagnosticLog.log("INVOKE openMainWindow (AppKit path); windows=[\(DiagnosticLog.windowSnapshot())]")
            showMainManagerWindow()
            if !UserDefaults.standard.bool(forKey: "hideDockIcon") {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
            UsageTracker.pingIfNeeded(source: .main)
            DiagnosticLog.logWindowsAfter("AFTER openMainWindow")
        }
        AppAction.shared.openSettings = {
            DiagnosticLog.log("INVOKE openSettings (AppKit path); windows=[\(DiagnosticLog.windowSnapshot())]")
            if !UserDefaults.standard.bool(forKey: "hideDockIcon") {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
            showSettingsWindowAppKit()
            DiagnosticLog.logWindowsAfter("AFTER openSettings")
        }
        AppAction.shared.openAutomationManager = {
            DiagnosticLog.log("INVOKE openAutomationManager (AppKit path); windows=[\(DiagnosticLog.windowSnapshot())]")
            if !UserDefaults.standard.bool(forKey: "hideDockIcon") {
                NSApp.setActivationPolicy(.regular)
            }
            showAutomationManagerWindow()
            NSApp.activate(ignoringOtherApps: true)
            DiagnosticLog.logWindowsAfter("AFTER openAutomationManager")
        }
        DiagnosticLog.log("registerAppActions: closures registered at launch (AppKit paths)")
    }

    // MARK: - Helpers

    private func hideAllMainWindows(_ sender: NSApplication) {
        var closed = 0
        for window in sender.windows where window.isVisible && window.canBecomeMain {
            window.close()
            closed += 1
        }
        DiagnosticLog.log("hideAllMainWindows: closed \(closed) window(s); now=[\(DiagnosticLog.windowSnapshot())]")
    }

    /// 诊断观察者:记录睡眠/唤醒、App 激活状态切换 —— 用来把「打不开设置」
    /// 与系统事件(长时间睡眠后唤醒、App Nap 等)对上号。issue #66。
    private func registerDiagnosticObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        let wsEvents: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "SYSTEM willSleep"),
            (NSWorkspace.didWakeNotification, "SYSTEM didWake"),
            (NSWorkspace.screensDidSleepNotification, "SYSTEM screensDidSleep"),
            (NSWorkspace.screensDidWakeNotification, "SYSTEM screensDidWake"),
        ]
        for (name, label) in wsEvents {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                DiagnosticLog.log(label)
            }
        }
    }

    static func applyAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

}
