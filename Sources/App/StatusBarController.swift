import AppKit
import Combine

/// 状态栏左键动作。右键始终弹菜单。
enum MenuBarLeftClickAction: String, CaseIterable {
    case menu              // 默认：弹菜单（跟右键一样）
    case openManager       // 打开管理器
    case quickPanel        // 打开快捷粘贴
    case toggleRelay       // 开启 / 退出接力
    case togglePause       // 暂停 / 继续剪贴板监听
    case openSettings      // 打开设置

    static let storageKey = "menuBarLeftClickAction"

    static var current: MenuBarLeftClickAction {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return MenuBarLeftClickAction(rawValue: raw) ?? .menu
    }

    var l10nKey: String {
        switch self {
        case .menu: return "menuBar.leftClick.menu"
        case .openManager: return "menuBar.leftClick.openManager"
        case .quickPanel: return "menuBar.leftClick.quickPanel"
        case .toggleRelay: return "menuBar.leftClick.toggleRelay"
        case .togglePause: return "menuBar.leftClick.togglePause"
        case .openSettings: return "menuBar.leftClick.openSettings"
        }
    }
}

/// 接管系统状态栏图标。替换原本 SwiftUI MenuBarExtra(.menu) 的实现，
/// 主要为了拿到左/右键的区分能力（MenuBarExtra 一律 = 弹菜单，没法做"左键执行某动作"）。
@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var observationTracking: Bool = false

    private override init() { super.init() }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refreshIcon()
        observeStateChanges()
    }

    // MARK: - Click handling

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let isRightClick = event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))

        if isRightClick {
            popUpMenu()
            return
        }

        switch MenuBarLeftClickAction.current {
        case .menu:
            popUpMenu()
        case .openManager:
            AppAction.shared.openMainWindow?()
        case .quickPanel:
            HotkeyManager.shared.showQuickPanel()
        case .toggleRelay:
            if RelayManager.shared.isActive {
                RelayManager.shared.deactivate()
            } else {
                RelayManager.shared.activate()
            }
        case .togglePause:
            ClipboardManager.shared.togglePause()
        case .openSettings:
            AppAction.shared.openSettings?()
        }
    }

    private func popUpMenu() {
        let menu = buildMenu()
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // 立刻清掉，下一次点击才能再次走 buttonClicked 自定义逻辑
        // （statusItem.menu 一旦设上，AppKit 会跳过 button.action）
        statusItem?.menu = nil
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // (条件) 授权辅助功能
        if !AccessibilityMonitor.shared.isTrusted {
            let item = makeItem(L10n.tr("menu.accessibility.grant"), action: #selector(grantAccessibility))
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // 打开管理器（带快捷键）
        let mgrShortcut: String = {
            if HotkeyManager.shared.isManagerCleared || !HotkeyManager.shared.isManagerHotkeyGlobalEnabled { return "" }
            return shortcutDisplayString(
                keyCode: HotkeyManager.shared.managerKeyCode,
                modifiers: HotkeyManager.shared.managerModifiers
            )
        }()
        let mgrTitle = mgrShortcut.isEmpty
            ? L10n.tr("menu.manager")
            : "\(L10n.tr("menu.manager"))    \(mgrShortcut)"
        menu.addItem(makeItem(mgrTitle, action: #selector(openManager)))

        // 快捷粘贴（带快捷键）
        let qpShortcut = HotkeyManager.shared.displayString
        let qpTitle = qpShortcut.isEmpty
            ? L10n.tr("menu.quickPanel")
            : "\(L10n.tr("menu.quickPanel"))    \(qpShortcut)"
        menu.addItem(makeItem(qpTitle, action: #selector(openQuickPanel)))

        // 暂停 / 继续剪贴板监听
        let pauseTitle = ClipboardManager.shared.isMonitoringEnabled
            ? L10n.tr("menu.pause")
            : L10n.tr("menu.resume")
        let pauseItem = makeItem(pauseTitle, action: #selector(togglePauseMonitoring))
        pauseItem.isEnabled = !RelayManager.shared.isActive
        menu.addItem(pauseItem)

        // 接力模式
        if RelayManager.shared.isActive {
            let title = "\(L10n.tr("relay.title")) (\(RelayManager.shared.progressText)) — \(L10n.tr("relay.exitRelay"))"
            menu.addItem(makeItem(title, action: #selector(toggleRelay)))
        } else {
            let shortcut = HotkeyManager.shared.isRelayCleared
                ? ""
                : shortcutDisplayString(
                    keyCode: HotkeyManager.shared.relayKeyCode,
                    modifiers: HotkeyManager.shared.relayModifiers
                )
            let title = shortcut.isEmpty
                ? L10n.tr("relay.startRelay")
                : "\(L10n.tr("relay.startRelay"))    \(shortcut)"
            menu.addItem(makeItem(title, action: #selector(toggleRelay)))
        }

        menu.addItem(.separator())

        // 管理自动化规则
        menu.addItem(makeItem(L10n.tr("settings.automation.manage"), action: #selector(openAutomationManager)))

        // 设置
        menu.addItem(makeItem(L10n.tr("menu.settings"), action: #selector(handleOpenSettings)))

        menu.addItem(.separator())

        // 退出
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PasteMemo"
        menu.addItem(makeItem(L10n.tr("menu.quit", appName), action: #selector(quitApp)))

        return menu
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Menu actions

    @objc private func grantAccessibility() {
        AccessibilityMonitor.shared.openAccessibilitySettings()
    }

    @objc private func openManager() {
        AppAction.shared.openMainWindow?()
    }

    @objc private func openQuickPanel() {
        HotkeyManager.shared.showQuickPanel()
    }

    @objc private func togglePauseMonitoring() {
        ClipboardManager.shared.togglePause()
    }

    @objc private func toggleRelay() {
        if RelayManager.shared.isActive {
            RelayManager.shared.deactivate()
        } else {
            RelayManager.shared.activate()
        }
    }

    @objc private func openAutomationManager() {
        AppAction.shared.openAutomationManager?()
    }

    @objc private func handleOpenSettings() {
        AppAction.shared.openSettings?()
    }

    @objc private func quitApp() {
        AppDelegate.shouldReallyQuit = true
        NSApp.terminate(nil)
    }

    // MARK: - Icon updates

    private func refreshIcon() {
        let style = UserDefaults.standard.string(forKey: "menuBarIconStyle") ?? "outline"
        let filled = style == "filled"
        let image = PasteMemoApp.menuBarIcon(
            paused: ClipboardManager.shared.isPaused,
            relay: RelayManager.shared.isActive,
            filled: filled
        )
        statusItem?.button?.image = image
    }

    // MARK: - State observation

    private func observeStateChanges() {
        // ClipboardManager 是 ObservableObject —— 直接订阅 objectWillChange。
        ClipboardManager.shared.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshIcon() }
            }
            .store(in: &cancellables)

        // RelayManager 是 @Observable —— 用 withObservationTracking 自递归订阅。
        trackRelayState()

        // 图标样式偏好（@AppStorage）变化时也要刷新。
        // KVO over UserDefaults 的语义：触发的 key 名 = setObject(_:forKey:) 写入的 key，
        // 与 getter 内部读哪个 key 无关。所以这个 @objc dynamic 属性名必须等于 @AppStorage
        // 写入的 key（"menuBarIconStyle"），否则 publisher 永远收不到通知。
        UserDefaults.standard.publisher(for: \.menuBarIconStyle)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshIcon() }
            }
            .store(in: &cancellables)
    }

    private func trackRelayState() {
        withObservationTracking {
            _ = RelayManager.shared.isActive
            _ = RelayManager.shared.isPaused
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshIcon()
                self?.trackRelayState()
            }
        }
    }
}

// 辅助 KVO key path：属性名必须 = @AppStorage 写入的 UserDefaults key，
// 否则 publisher(for:) 收不到通知（见上面 observeStateChanges 的注释）。
private extension UserDefaults {
    @objc dynamic var menuBarIconStyle: String? {
        string(forKey: "menuBarIconStyle")
    }
}
