import AppKit
import SwiftUI
import SwiftData

extension Notification.Name {
    static let quickPanelDidShow = Notification.Name("quickPanelDidShow")
    static let quickPanelWillDismiss = Notification.Name("quickPanelWillDismiss")
    static let quickPanelPinnedResignKey = Notification.Name("quickPanelPinnedResignKey")
    /// 置顶时全局 ⌘1–9 命中，userInfo["index"] 为 1–9，由 QuickPanelView 粘贴对应项（不关面板）
    static let quickPanelPasteDigit = Notification.Name("quickPanelPasteDigit")
    /// 置顶期间用户切到别的前台 App，粘贴目标已更新，QuickPanelView 据此刷新底部"粘贴到 X"
    static let quickPanelPasteTargetChanged = Notification.Name("quickPanelPasteTargetChanged")
}

private let DEFAULT_WIDTH: CGFloat = 750
private let DEFAULT_HEIGHT: CGFloat = 510
private let MIN_WIDTH: CGFloat = 360
private let MIN_HEIGHT: CGFloat = 420

/// Below this width the preview pane is hidden and the list fills the full width.
let QUICK_PANEL_PREVIEW_BREAKPOINT: CGFloat = 620

/// Observable state shared between QuickPanelWindowController (AppKit) and
/// QuickPanelView (SwiftUI). The controller updates `width` on NSWindow resize;
/// SwiftUI re-renders the layout reactively.
@MainActor
final class QuickPanelLayoutState: ObservableObject {
    @Published var width: CGFloat
    init(width: CGFloat) { self.width = width }
    var shouldShowPreview: Bool { width >= QUICK_PANEL_PREVIEW_BREAKPOINT }
}
private let TOP_INSET_RATIO: CGFloat = 0.15
private let SIZE_KEY = "quickPanelSize"
private let POSITION_KEY = "quickPanelPosition"
private let POSITION_SCREEN_KEY = "quickPanelPosition.screenID"

private class KeyablePanel: NSPanel {
    /// When true, the panel refuses to become key — used in pinned mode so the search
    /// field's FocusState can't drag keyboard focus back to the panel while the user
    /// types in another app.
    var refuseKey = false

    override var canBecomeKey: Bool { !refuseKey }
    override var canBecomeMain: Bool { !refuseKey }

    // borderless + titled 混合 styleMask 下系统不强制 minSize，手动 clamp
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var clamped = frameRect
        clamped.size.width = max(clamped.size.width, minSize.width)
        clamped.size.height = max(clamped.size.height, minSize.height)
        super.setFrame(clamped, display: flag)
    }
}

/// Transparent view that absorbs titlebar clicks so they become background drags
private class DragOnlyView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        // Don't call super — prevent system titlebar drag handling
        window?.performDrag(with: event)
    }
}

@MainActor
final class QuickPanelWindowController {
    static let shared = QuickPanelWindowController()

    private var panel: NSPanel?
    private var layoutState: QuickPanelLayoutState?
    private var clickOutsideMonitor: Any?
    private var deactivationObserver: Any?
    private var resignKeyObserver: Any?
    /// 置顶期间跟踪前台 App 切换，让粘贴目标跟随当前 App
    private var pinnedActivationObserver: Any?
    private var resizeObserver: Any?
    private(set) var previousApp: NSRunningApplication?
    /// 面板弹出瞬间，`previousApp` 的键盘焦点是否落在文本输入控件上。
    /// Finder 的「存到当前文件夹」分支据此让路：焦点在搜索框 / 重命名框里时，用户要的是
    /// 把内容粘进那个框，而不是在文件夹里生成一个 .txt / 图片文件。只看「目标 App 是不是
    /// Finder」会把这两种意图混为一谈——Finder 搜索框粘贴因此完全失效（只默默建了个文件）。
    private(set) var previousFocusIsTextInput = false
    private var isWarmedUp = false
    var isPinned = false {
        didSet {
            guard isPinned != oldValue else { return }
            (panel as? KeyablePanel)?.refuseKey = isPinned
            if isPinned {
                // Post notification so SwiftUI view clears FocusState before we resign key.
                NotificationCenter.default.post(name: .quickPanelPinnedResignKey, object: nil)
                // Hand key status to the previously-focused app so the user can type there.
                if panel?.isKeyWindow == true {
                    previousApp?.activate(options: [])
                }
                // 面板已让出焦点，local 监听器收不到键了；改用全局 ⌘1–9 支持连续快粘。
                HotkeyManager.shared.registerQuickPasteDigitHotkeys()
            } else {
                // 取消置顶：把 ⌘1–9 还给目标 App。
                HotkeyManager.shared.unregisterQuickPasteDigitHotkeys()
            }
        }
    }
    var suppressDismiss = false
    private var snapGuide: SnapGuideWindow?

    private var panelWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "\(SIZE_KEY).width")
        return saved > 0 ? max(saved, MIN_WIDTH) : DEFAULT_WIDTH
    }

    private var panelHeight: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "\(SIZE_KEY).height")
        return saved > 0 ? max(saved, MIN_HEIGHT) : DEFAULT_HEIGHT
    }

    private var positionMode: QuickPanelPositionMode {
        let rawValue = UserDefaults.standard.string(forKey: QuickPanelPositionSettings.modeKey)
        return QuickPanelPositionMode(rawValue: rawValue ?? "") ?? .screenCenter
    }

    private var screenTarget: QuickPanelScreenTarget {
        let rawValue = UserDefaults.standard.string(forKey: QuickPanelPositionSettings.screenTargetKey)
        return QuickPanelScreenTarget(rawValue: rawValue ?? "") ?? .active
    }

    private var specifiedScreenID: String? {
        let value = UserDefaults.standard.string(forKey: QuickPanelPositionSettings.specifiedScreenIDKey)
        return value?.isEmpty == true ? nil : value
    }

    private var isLaunchAnimationEnabled: Bool {
        guard UserDefaults.standard.object(forKey: QuickPanelSettings.launchAnimationEnabledKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: QuickPanelSettings.launchAnimationEnabledKey)
    }

    private init() {}

    /// Call once at app launch to pre-build the panel off-screen
    func warmUp(clipboardManager: ClipboardManager, modelContainer: ModelContainer) {
        guard !isWarmedUp else { return }
        let panel = buildPanel(clipboardManager: clipboardManager, modelContainer: modelContainer)
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.displayIfNeeded()

        // 把缩放动画的 anchor point 提前设好，show 时就不会再跳
        if let contentView = panel.contentView {
            contentView.wantsLayer = true
            let bounds = contentView.bounds
            contentView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            contentView.layer?.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        panel.orderOut(nil)
        self.panel = panel
        isWarmedUp = true
    }

    func show(clipboardManager: ClipboardManager, modelContainer: ModelContainer) {
        if let existing = panel, existing.isVisible {
            // 再次按开关热键 = 用户主动关闭，置顶时也要关
            dismiss(force: true)
            return
        }

        previousApp = NSWorkspace.shared.frontmostApplication
        // 必须在下面 makeKey() 之前采样：抢了 key 之后读到的可能已是面板自己的焦点。
        previousFocusIsTextInput = Self.focusIsTextInput(previousApp)

        if !isWarmedUp {
            warmUp(clipboardManager: clipboardManager, modelContainer: modelContainer)
        }

        guard let panel else { return }

        positionPanel(panel)

        let shouldAnimate = isLaunchAnimationEnabled

        if shouldAnimate {
            // 起始状态：alpha 0 + scale 0.995（极轻微缩放）
            panel.alphaValue = 0
            if let layer = panel.contentView?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.removeAnimation(forKey: "showScale")
                layer.transform = CATransform3DMakeScale(0.995, 0.995, 1)
                CATransaction.commit()
            }
        } else {
            panel.alphaValue = 1
            if let layer = panel.contentView?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.removeAnimation(forKey: "showScale")
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        }

        panel.orderFrontRegardless()
        panel.makeKey()

        if shouldAnimate {
            // 动画到 alpha 1 + scale 1.0（仅作轻微空间引导，时长 0.1s）
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            if let layer = panel.contentView?.layer {
                let anim = CABasicAnimation(keyPath: "transform")
                anim.fromValue = CATransform3DMakeScale(0.995, 0.995, 1)
                anim.toValue = CATransform3DIdentity
                anim.duration = 0.1
                anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(anim, forKey: "showScale")
                layer.transform = CATransform3DIdentity
            }
        }

        installClickOutsideMonitor()
        installDeactivationObserver()
        installMoveObserver()
        NotificationCenter.default.post(name: .quickPanelDidShow, object: nil)
        UsageTracker.pingIfNeeded(source: .quick)
    }

    /// 粘贴动作发生时重采一次目标 App 的焦点——**仅置顶模式**。
    ///
    /// 置顶时面板不持有 key，用户可以在目标 App 里自由移动焦点（比如在 Finder 里从文件
    /// 列表点进搜索框），而这**不会**发出任何系统通知，`show()` / App 激活时采的值就过期了。
    /// 非置顶时面板已抢走 key，此刻读到的是面板自己的焦点，只能沿用 `show()` 时的采样。
    func refreshTargetFocusIfPinned() {
        guard isPinned else { return }
        previousFocusIsTextInput = Self.focusIsTextInput(previousApp)
    }

    /// 焦点落在这些 AX 角色上时，用户的意图是「往这个框里打字」，而不是操作 App 的主内容区。
    private static let TEXT_INPUT_AX_ROLES: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// 采样目标 App 此刻的键盘焦点是不是文本输入控件。
    ///
    /// 必须在面板 `makeKey()` **之前**调用。无辅助功能权限、目标 App 不响应 AX、
    /// 或焦点不在文本控件上时一律返回 false —— 即退回既有行为，不会让粘贴变得更差。
    private static func focusIsTextInput(_ app: NSRunningApplication?) -> Bool {
        guard let pid = app?.processIdentifier else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        // 目标 App 卡住时 AX 查询默认要等好几秒，会把面板弹出一起拖住；限死 200ms。
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }
        let element = focusedRef as! AXUIElement
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return false }
        return TEXT_INPUT_AX_ROLES.contains(role)
    }

    /// - Parameter force: 置顶时，粘贴/复制完成的收尾调用（`force == false`）不关闭面板，
    ///   让用户连续操作；只有用户主动关闭（Esc / 再次按开关热键 / 关闭按钮等）才传 `force: true`。
    func dismiss(force: Bool = false) {
        if isPinned && !force { return }
        isPinned = false
        removeClickOutsideMonitor()
        removeDeactivationObserver()
        guard let panel else {
            HotkeyManager.shared.isQuickPanelVisible = false
            return
        }
        removeMoveObserver()
        snapGuide?.orderOut(nil)
        savePosition(panel)
        // 命令面板是 SwiftUI `.popover`（NSPopover 子窗口）。下面 layoutSubtreeIfNeeded 会同步把
        // showCommandPalette=false 刷下去、触发 NSPopover.close() 的 ~200ms 关闭动画——粘贴瞬间完成、
        // 浮层还在淡出，就成了"先粘后关"。teardown 时先把子窗口无动画 orderOut，等会触发 close() 时
        // 已无可见内容可动画，浮层和面板一起干脆消失。
        for child in panel.childWindows ?? [] {
            child.animationBehavior = .none
            child.orderOut(nil)
        }
        // 先通知视图清理状态（搜索文本、pill 等），强制 SwiftUI 完成一次重绘后再隐藏 panel；
        // 这样下次打开时首帧是干净状态，不会闪现上次的 `/` 建议浮层
        NotificationCenter.default.post(name: .quickPanelWillDismiss, object: nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        // 焦点交还只发生在用户主动关闭（Esc/热键，force=true）。点击外部时
        // （force=false）系统正在激活用户点的 App，我们再 activate(previousApp)
        // 会跟它抢前台——两个激活来回切就是「面板消失时闪来闪去」，且竞态赢了
        // 还会把焦点从用户点的 App 拉回旧 App。粘贴路径不依赖这里：
        // dismissAndPaste 自己 activate 目标 App。
        orderOutAvoidingKeyProposal(panel, restoreFocus: force)
        HotkeyManager.shared.isQuickPanelVisible = false
    }

    /// macOS 26 (Tahoe) 的窗口协调器（NSWMWindowCoordinator）在 orderOut 一个**可成为
    /// key** 且仍持有 key 状态的窗口时，会跨进程向窗口服务器提议下一个 key 窗口并同步
    /// 等待回复；对非激活 App 的 nonactivating 面板，提议得不到应答，主线程干等约 0.4s
    /// 超时——Esc 关闭面板肉眼可见地卡住。行为探测（探针实测）发现：先把面板置为
    /// `refuseKey`（canBecomeKey=false）再 orderOut，协调器不再发起提议，orderOut 即刻
    /// 返回。`restoreFocus` 为 true（用户主动关闭）时顺带把焦点交还目标 App；点击
    /// 外部触发的 dismiss 传 false——mouseDown 全局监视器早于系统完成「点击激活目标
    /// App」，此刻面板往往仍是 key，这里再 activate(previousApp) 会跟系统抢前台。
    private func orderOutAvoidingKeyProposal(_ panel: NSPanel, restoreFocus: Bool) {
        guard panel.isKeyWindow, let keyable = panel as? KeyablePanel else {
            panel.orderOut(nil)
            return
        }
        keyable.refuseKey = true
        if restoreFocus {
            previousApp?.activate(options: [])
        }
        panel.orderOut(nil)
        // isPinned 在 dismiss 里已重置为 false；恢复可 makeKey 供下次 show 使用
        keyable.refuseKey = isPinned
    }

    func dismissAndPaste(_ item: ClipItem, clipboardManager: ClipboardManager, addNewLine: Bool = false) {
        let appToRestore = previousApp
        clipboardManager.writeToPasteboard(item, targetApp: appToRestore)
        SoundManager.playPaste()

        // 置顶连续快粘：保留面板、保留 previousApp、不更新 lastUsedAt（否则列表重排、⌘1–9 编号错位）。
        // 仍激活目标 App 再 ⌘V——面板有时仍是 key window，不激活会把 ⌘V 投给面板自己。
        if !isPinned {
            item.lastUsedAt = Date()
            if let context = item.modelContext {
                ClipItemStore.saveAndNotifyLastUsed(context)
            }
            dismiss()
            previousApp = nil
            previousFocusIsTextInput = false
        }

        // 延迟 orderOut 机制下 dismiss 返回时面板可能仍持有 key，立刻发合成 ⌘V 会落空
        // （1.7.12-beta.1 回归：升级后粘贴无效）。排到关闭落地后执行；置顶（未 dismiss）时立即执行。
        // ⌘V 用 postToPid 直投目标进程（见 simulatePaste），不依赖窗口服务器的键盘路由，
        // dismiss 一返回立即粘贴——零附加延迟。
        if let app = appToRestore {
            app.activate()
            clipboardManager.simulatePaste(forceNewLine: addNewLine, targetApp: app)
        }
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Panel Construction

    private func buildPanel(clipboardManager: ClipboardManager, modelContainer: ModelContainer) -> NSPanel {
        let initialWidth = panelWidth
        let state = QuickPanelLayoutState(width: initialWidth)
        self.layoutState = state

        let content = QuickPanelView()
            .environmentObject(clipboardManager)
            .environmentObject(state)
            .modelContainer(modelContainer)

        let hosting = NSHostingController(rootView: content.ignoresSafeArea())

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .titled, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // .floating(3) 离 .normal(0) 太近：作为后台非激活面板，前台 App 的普通窗口会被系统
        // 抬到同层之上，把面板盖住（剪映导出框 level=0 仍遮住面板，issue #78）。提到 .statusBar(25)
        // 拉开层差，与项目内 Toast / Maccy / Clippy 命令面板的做法一致。
        panel.level = .statusBar
        // 跨 Space / 全屏跟随，否则全屏 App 下面板不出现。项目内 Toast / Relay 都设了，唯独这里漏。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        // Cover the titlebar with a draggable view so clicks there
        // go through isMovableByWindowBackground instead of system titlebar handling
        let titlebarCover = NSTitlebarAccessoryViewController()
        titlebarCover.layoutAttribute = .top
        let coverView = DragOnlyView(frame: NSRect(x: 0, y: 0, width: 0, height: 1))
        coverView.autoresizingMask = [.width]
        titlebarCover.view = coverView
        panel.addTitlebarAccessoryViewController(titlebarCover)

        let hostingView = hosting.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // Raycast 同款方案：外观锁定的系统材质（浅色外观=浅底、深色=深底，亮度
        // 不随背后内容漂移），而非 NSGlassEffectView——玻璃的最终亮度由背后内容
        // 主导且 tintColor 压不住（探针实锤：浅色外观叠黑背景，tint 1.0 仍是中灰，
        // 黑字直接糊掉），大面积文字面板在外观与背景明暗错配时必然发灰。Liquid
        // Glass 只用在系统原生支持的场景（设置窗口侧边栏、popover 材质背景）。
        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true

        let visualEffect = NSVisualEffectView(frame: container.bounds)
        visualEffect.material = .headerView
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]
        container.addSubview(visualEffect)

        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        panel.contentView = container
        panel.minSize = NSSize(width: MIN_WIDTH, height: MIN_HEIGHT)

        // Save size when resized. warmUp runs once so registering here is safe;
        // we still track the token so a future rebuild path wouldn't duplicate writes.
        if let previous = resizeObserver {
            NotificationCenter.default.removeObserver(previous)
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak panel, weak state] _ in
            Task { @MainActor in
                guard let size = panel?.frame.size else { return }
                UserDefaults.standard.set(Double(size.width), forKey: "\(SIZE_KEY).width")
                UserDefaults.standard.set(Double(size.height), forKey: "\(SIZE_KEY).height")
                state?.width = size.width
            }
        }

        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        switch positionMode {
        case .remembered:
            positionRemembered(panel)
        case .cursor:
            positionAtCursor(panel)
        case .menuBarIcon:
            positionAtMenuBarIcon(panel)
        case .windowCenter:
            positionAtWindowCenter(panel)
        case .screenCenter:
            positionAtScreenCenter(panel)
        }
    }

    /// Position panel on the screen where the mouse is, using saved relative offset if available.
    private func positionRemembered(_ panel: NSPanel) {
        let hasSaved = UserDefaults.standard.object(forKey: "\(POSITION_KEY).rx") != nil
        if hasSaved,
           let screen = rememberedScreen() ?? NSScreen.screenWithMouse ?? NSScreen.main ?? NSScreen.screens.first {
            let visibleFrame = screen.visibleFrame
            // Saved offset is relative to the screen's visible frame (0.0~1.0 ratio).
            // Clamp so the panel stays on-screen if the display shrunk or was swapped.
            let rx = UserDefaults.standard.double(forKey: "\(POSITION_KEY).rx")
            let ry = UserDefaults.standard.double(forKey: "\(POSITION_KEY).ry")
            let origin = CGPoint(
                x: visibleFrame.origin.x + rx * visibleFrame.width,
                y: visibleFrame.origin.y + ry * visibleFrame.height
            )
            setClampedOrigin(origin, for: panel, on: screen)
        } else {
            let screen = NSScreen.screenWithMouse ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { return }
            centerOnScreen(panel, screen: screen)
        }
    }

    private func rememberedScreen() -> NSScreen? {
        let screenID = UserDefaults.standard.string(forKey: POSITION_SCREEN_KEY)
        return ScreenLocator.screen(for: screenID)
    }

    private func centerOnScreen(_ panel: NSPanel, screen: NSScreen) {
        let frame = screen.visibleFrame
        let x = frame.midX - panel.frame.width / 2
        let y = preferredUpperCenterY(screen: screen, panelHeight: panel.frame.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func centerOnScreenExact(_ panel: NSPanel, screen: NSScreen) {
        let frame = screen.visibleFrame
        let x = frame.midX - panel.frame.width / 2
        let y = frame.midY - panel.frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// IME-style placement: anchor the panel to whichever corner of the cursor
    /// has the most room, so the panel never spills off-screen and never sits
    /// directly on top of where the user was just looking. Picks horizontal
    /// side (right vs left of cursor) and vertical side (below vs above)
    /// independently — the 4 combinations cover any cursor location.
    private func positionAtCursor(_ panel: NSPanel) {
        guard let screen = NSScreen.screenWithMouse ?? resolveTargetScreen() else { return }
        let mouse = NSEvent.mouseLocation
        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let gap: CGFloat = 8

        // Cocoa coords: origin = bottom-left of screen, y grows upward.
        let spaceRight = visibleFrame.maxX - mouse.x
        let spaceLeft = mouse.x - visibleFrame.minX
        let placeRight = spaceRight >= panelSize.width + gap || spaceRight >= spaceLeft

        let spaceBelow = mouse.y - visibleFrame.minY
        let spaceAbove = visibleFrame.maxY - mouse.y
        let placeBelow = spaceBelow >= panelSize.height + gap || spaceBelow >= spaceAbove

        let originX = placeRight
            ? mouse.x + gap
            : mouse.x - gap - panelSize.width
        let originY = placeBelow
            ? mouse.y - gap - panelSize.height
            : mouse.y + gap

        setClampedOrigin(CGPoint(x: originX, y: originY), for: panel, on: screen)
    }

    private func positionAtMenuBarIcon(_ panel: NSPanel) {
        if let anchor = MenuBarIconLocator.iconFrame() {
            let origin = CGPoint(
                x: anchor.frame.midX - panel.frame.width / 2,
                y: anchor.frame.minY - panel.frame.height - 8
            )
            setClampedOrigin(origin, for: panel, on: anchor.screen)
            return
        }

        guard let screen = resolveTargetScreen() else { return }
        centerOnScreenExact(panel, screen: screen)
    }

    private func positionAtWindowCenter(_ panel: NSPanel) {
        if let frame = ActiveWindowLocator.focusedWindowFrame(),
           let screen = ScreenLocator.screen(for: frame) {
            let origin = CGPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2
            )
            setClampedOrigin(origin, for: panel, on: screen)
            return
        }

        guard let screen = resolveTargetScreen() else { return }
        centerOnScreenExact(panel, screen: screen)
    }

    private func positionAtScreenCenter(_ panel: NSPanel) {
        guard let screen = resolveTargetScreen() else { return }
        centerOnScreen(panel, screen: screen)
    }

    private func resolveTargetScreen() -> NSScreen? {
        switch screenTarget {
        case .active:
            ActiveWindowLocator.activeScreen()
        case .specified:
            ScreenLocator.screen(for: specifiedScreenID)
                ?? ActiveWindowLocator.activeScreen()
                ?? NSScreen.screenWithMouse
                ?? NSScreen.main
                ?? NSScreen.screens.first
        }
    }

    private func setClampedOrigin(_ origin: CGPoint, for panel: NSPanel, on screen: NSScreen) {
        let clamped = clampedOrigin(origin, panelSize: panel.frame.size, visibleFrame: screen.visibleFrame)
        panel.setFrameOrigin(clamped)
    }

    private func clampedOrigin(_ origin: CGPoint, panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
        return CGPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "\(POSITION_KEY).rx")
        UserDefaults.standard.removeObject(forKey: "\(POSITION_KEY).ry")
        UserDefaults.standard.removeObject(forKey: POSITION_SCREEN_KEY)
        guard let panel, panel.isVisible else { return }
        positionPanel(panel)
    }

    private func savePosition(_ panel: NSPanel) {
        // Save position as relative offset within the screen's visible frame
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) })
                ?? NSScreen.screenWithMouse else { return }
        let visibleFrame = screen.visibleFrame
        // Guard against transient 0-sized frames during display reconfiguration,
        // which would produce NaN and permanently break remembered-position mode.
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return }
        let rx = (panel.frame.origin.x - visibleFrame.origin.x) / visibleFrame.width
        let ry = (panel.frame.origin.y - visibleFrame.origin.y) / visibleFrame.height
        UserDefaults.standard.set(rx, forKey: "\(POSITION_KEY).rx")
        UserDefaults.standard.set(ry, forKey: "\(POSITION_KEY).ry")
        UserDefaults.standard.set(ScreenLocator.identifier(for: screen), forKey: POSITION_SCREEN_KEY)
    }

    private func installClickOutsideMonitor() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if self.isPinned || self.suppressDismiss { return }
            if let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) { return }
            Task { @MainActor in
                self.dismiss()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        guard let monitor = clickOutsideMonitor else { return }
        NSEvent.removeMonitor(monitor)
        clickOutsideMonitor = nil
    }

    private func installDeactivationObserver() {
        // App resign active (e.g. Cmd+Tab when app was active)
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isPinned, !self.suppressDismiss else { return }
                let isMouseDown = NSEvent.pressedMouseButtons != 0
                let mouseInPanel = self.panel?.frame.contains(NSEvent.mouseLocation) ?? false
                if isMouseDown, mouseInPanel { return }
                self.dismiss()
            }
        }
        // Panel lost key (e.g. another window took focus, or Cmd+Tab)
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.suppressDismiss else { return }
                if self.isPinned {
                    // When pinned and panel loses key (user clicked another app), release
                    // the SwiftUI FocusState so it stops fighting to become key again.
                    NotificationCenter.default.post(name: .quickPanelPinnedResignKey, object: nil)
                    return
                }
                let isMouseDown = NSEvent.pressedMouseButtons != 0
                let mouseInPanel = self.panel?.frame.contains(NSEvent.mouseLocation) ?? false
                if isMouseDown, mouseInPanel { return }
                self.dismiss()
            }
        }
        // 置顶悬浮时用户会在多个 App 间切换。粘贴目标 previousApp 原本只在 show() 时记录一次，
        // 切到 Word 后还停在打开面板时的 App（如微信）。这里跟踪前台 App 切换，把 previousApp
        // 实时更新成当前 App（排除 PasteMemo 自己），所有读 previousApp 的粘贴路径自动跟随。
        pinnedActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPinned else { return }
                // 读 frontmostApplication（刚激活的就是它），避免把 Notification 捕获进
                // 主 actor 闭包触发数据竞争；也更"实时"。
                guard let app = NSWorkspace.shared.frontmostApplication,
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self.previousApp = app
                // 置顶时面板已让出 key，这里读到的就是目标 App 自己的焦点。
                self.previousFocusIsTextInput = Self.focusIsTextInput(app)
                NotificationCenter.default.post(name: .quickPanelPasteTargetChanged, object: nil)
            }
        }
    }

    private func removeDeactivationObserver() {
        if let obs = deactivationObserver {
            NotificationCenter.default.removeObserver(obs)
            deactivationObserver = nil
        }
        if let obs = resignKeyObserver {
            NotificationCenter.default.removeObserver(obs)
            resignKeyObserver = nil
        }
        if let obs = pinnedActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            pinnedActivationObserver = nil
        }
    }

    // MARK: - Snap Guides

    private static let SNAP_THRESHOLD: CGFloat = 20
    private var snappedH = false
    private var snappedV = false
    private var moveObserver: Any?
    private var mouseUpMonitor: Any?
    private var globalMouseUpMonitor: Any?

    private func installMoveObserver() {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWindowMove()
            }
        }
        let onMouseUp: () -> Void = { [weak self] in
            self?.snapGuide?.orderOut(nil)
            self?.snapToGuideIfNeeded()
            self?.snappedH = false
            self?.snappedV = false
            self?.panel?.makeKey()
        }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            onMouseUp()
            return event
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            onMouseUp()
        }
    }

    private func removeMoveObserver() {
        if let obs = moveObserver { NotificationCenter.default.removeObserver(obs); moveObserver = nil }
        if let obs = mouseUpMonitor { NSEvent.removeMonitor(obs); mouseUpMonitor = nil }
        if let obs = globalMouseUpMonitor { NSEvent.removeMonitor(obs); globalMouseUpMonitor = nil }
    }

    private func recommendedTopY(screen: NSScreen, panelHeight: CGFloat) -> CGFloat {
        preferredUpperCenterY(screen: screen, panelHeight: panelHeight)
    }

    private func preferredUpperCenterY(screen: NSScreen, panelHeight: CGFloat) -> CGFloat {
        let visibleFrame = screen.visibleFrame
        let topInset = visibleFrame.height * TOP_INSET_RATIO
        return visibleFrame.maxY - topInset - panelHeight
    }

    private func handleWindowMove() {
        guard let panel, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) })
                ?? NSScreen.screenWithMouse else { return }

        let visibleFrame = screen.visibleFrame
        let panelFrame = panel.frame

        let hDist = abs(panelFrame.midX - visibleFrame.midX)
        let recTopY = recommendedTopY(screen: screen, panelHeight: panelFrame.height)
        let topDist = abs(panelFrame.origin.y - recTopY)
        let vCenterDist = abs(panelFrame.midY - visibleFrame.midY)
        let nearTop = topDist < vCenterDist

        let showH = hDist < Self.SNAP_THRESHOLD
        let showV = (nearTop ? topDist : vCenterDist) < Self.SNAP_THRESHOLD

        if showH, !snappedH { hapticFeedback(); snappedH = true }
        if !showH { snappedH = false }
        if showV, !snappedV { hapticFeedback(); snappedV = true }
        if !showV { snappedV = false }

        let guideTopY = visibleFrame.maxY - visibleFrame.height * TOP_INSET_RATIO
        updateSnapGuide(on: screen, horizontal: showH, verticalCenter: showV && !nearTop, recommendedTop: showV && nearTop, guideTopY: guideTopY)
    }

    private func snapToGuideIfNeeded() {
        guard let panel else { return }
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) })
                ?? NSScreen.screenWithMouse else { return }

        let visibleFrame = screen.visibleFrame
        let panelFrame = panel.frame
        var origin = panelFrame.origin
        var didSnap = false

        if abs(panelFrame.midX - visibleFrame.midX) < Self.SNAP_THRESHOLD {
            origin.x = visibleFrame.midX - panelFrame.width / 2; didSnap = true
        }
        let recTopY = recommendedTopY(screen: screen, panelHeight: panelFrame.height)
        if abs(panelFrame.origin.y - recTopY) < Self.SNAP_THRESHOLD {
            origin.y = recTopY; didSnap = true
        } else if abs(panelFrame.midY - visibleFrame.midY) < Self.SNAP_THRESHOLD {
            origin.y = visibleFrame.midY - panelFrame.height / 2; didSnap = true
        }
        if didSnap { panel.setFrameOrigin(origin) }
    }

    private func hapticFeedback() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func updateSnapGuide(on screen: NSScreen, horizontal: Bool, verticalCenter: Bool, recommendedTop: Bool, guideTopY: CGFloat) {
        if horizontal || verticalCenter || recommendedTop {
            let guide = snapGuide ?? SnapGuideWindow(screen: screen)
            guide.update(screen: screen, showHorizontal: horizontal, showVerticalCenter: verticalCenter, showRecommendedTop: recommendedTop, recommendedTopY: guideTopY)
            guide.orderFront(nil)
            snapGuide = guide
        } else {
            snapGuide?.orderOut(nil)
        }
    }
}

// MARK: - Snap Guide Overlay Window

private class SnapGuideWindow: NSWindow {
    private let guideView = SnapGuideView()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.isReleasedWhenClosed = false
        self.isOpaque = false
        self.backgroundColor = .clear
        // 比面板高 1 层，保证拖动时对齐参考线显示在面板之上（面板已抬到 .statusBar，见 buildPanel）。
        self.level = .statusBar + 1
        self.ignoresMouseEvents = true
        self.hasShadow = false
        self.contentView = guideView
    }

    func update(screen: NSScreen, showHorizontal: Bool, showVerticalCenter: Bool, showRecommendedTop: Bool, recommendedTopY: CGFloat) {
        setFrame(screen.frame, display: false)
        guideView.showHorizontal = showHorizontal
        guideView.showVerticalCenter = showVerticalCenter
        guideView.showRecommendedTop = showRecommendedTop
        // Convert screen coordinate to view coordinate
        guideView.recommendedTopLocalY = recommendedTopY - screen.frame.origin.y
        guideView.needsDisplay = true
    }
}

private class SnapGuideView: NSView {
    var showHorizontal = false
    var showVerticalCenter = false
    var showRecommendedTop = false
    var recommendedTopLocalY: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let color = NSColor.gray.withAlphaComponent(0.4).cgColor
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])

        if showHorizontal {
            ctx.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
            ctx.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
            ctx.strokePath()
        }
        if showVerticalCenter {
            ctx.move(to: CGPoint(x: bounds.minX, y: bounds.midY))
            ctx.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
            ctx.strokePath()
        }
        if showRecommendedTop {
            ctx.move(to: CGPoint(x: bounds.minX, y: recommendedTopLocalY))
            ctx.addLine(to: CGPoint(x: bounds.maxX, y: recommendedTopLocalY))
            ctx.strokePath()
        }
    }
}

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouseLocation) }
    }
}
