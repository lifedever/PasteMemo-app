import AppKit
import SwiftUI

/// 贴边条上线后给老用户弹一次的介绍窗口。
///
/// 只看「完成过新手引导」，不比版本号：哪个版本第一次跑到这段代码，用户就是刚从
/// 没有这个功能的版本升上来。全新安装的用户走新手引导，介绍直接记为看过，免得他们
/// 引导完、下次启动又弹一个「新功能」。
@MainActor
enum ShelfIntro {
    static let seenKey = "shelfIntroShown"
    private static let windowID = "shelfIntro"
    /// 启动后稍等再弹，别跟状态栏图标、更新检查挤在同一瞬间
    private static let launchDelay: TimeInterval = 1.5

    enum LaunchAction: Equatable {
        case present
        case markSeen
        case nothing
    }

    /// 启动时该怎么处理。纯函数，方便把「全新安装 / 老用户 / 权限丢了 / 看过了」几条路测一遍。
    nonisolated static func launchAction(seen: Bool, hasCompletedOnboarding: Bool, needsAccessibility: Bool) -> LaunchAction {
        if seen { return .nothing }
        if !hasCompletedOnboarding { return .markSeen }
        // 辅助功能权限丢了的老用户这次先处理权限弹窗，介绍留到下次启动
        if needsAccessibility { return .nothing }
        return .present
    }

    static func handleLaunch(hasCompletedOnboarding: Bool, needsAccessibility: Bool) {
        let defaults = UserDefaults.standard
        let action = launchAction(
            seen: defaults.bool(forKey: seenKey),
            hasCompletedOnboarding: hasCompletedOnboarding,
            needsAccessibility: needsAccessibility
        )
        switch action {
        case .present:
            DispatchQueue.main.asyncAfter(deadline: .now() + launchDelay) { present() }
        case .markSeen:
            defaults.set(true, forKey: seenKey)
        case .nothing:
            break
        }
    }

    static func present() {
        // 弹出即算看过：用户点红色关闭按钮关掉也不再弹
        UserDefaults.standard.set(true, forKey: seenKey)
        WindowManager.shared.show(
            id: windowID,
            title: L10n.tr("shelfIntro.title"),
            size: NSSize(width: ShelfIntroView.width, height: 640),
            floating: false,
            styleMask: [.titled, .closable, .fullSizeContentView],
            autoResizesToContent: true,
            content: {
                ShelfIntroView(
                    onTry: { tryShelf() },
                    onKeep: { close() },
                    onOpenSettings: {
                        close()
                        openSettings(category: .quickPanel)
                    }
                )
            },
            beforeShow: { window in
                // 动画区一直铺到窗口顶上，标题栏只留红绿灯
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
            }
        )
    }

    private static func close() {
        WindowManager.shared.close(id: windowID)
    }

    /// 切到贴边条，关掉介绍窗口，马上弹一次贴边条给用户看。
    private static func tryShelf() {
        UserDefaults.standard.set(QuickPanelPresentation.shelf.rawValue, forKey: QuickPanelSettings.presentationKey)
        close()
        // 介绍窗口是 PasteMemo 自己的窗口，关掉后先把前台还给原来的 App：贴边条按
        // 那个 App 的光标决定贴哪条边，粘贴目标也是它
        NSApp.deactivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            HotkeyManager.shared.showQuickPanel()
        }
    }
}
