import AppKit
import SwiftUI
import SwiftData

extension Notification.Name {
    static let quickPanelDidShow = Notification.Name("quickPanelDidShow")
    static let quickPanelWillDismiss = Notification.Name("quickPanelWillDismiss")
    static let quickPanelPinnedResignKey = Notification.Name("quickPanelPinnedResignKey")
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
    private var resizeObserver: Any?
    private(set) var previousApp: NSRunningApplication?
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
            dismiss()
            return
        }

        previousApp = NSWorkspace.shared.frontmostApplication

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

    func dismiss() {
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
        // 先通知视图清理状态（搜索文本、pill 等），强制 SwiftUI 完成一次重绘后再隐藏 panel；
        // 这样下次打开时首帧是干净状态，不会闪现上次的 `/` 建议浮层
        NotificationCenter.default.post(name: .quickPanelWillDismiss, object: nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        HotkeyManager.shared.isQuickPanelVisible = false
    }

    func dismissAndPaste(_ item: ClipItem, clipboardManager: ClipboardManager, addNewLine: Bool = false) {
        let appToRestore = previousApp
        clipboardManager.writeToPasteboard(item, targetApp: appToRestore)
        item.lastUsedAt = Date()
        if let context = item.modelContext {
            ClipItemStore.saveAndNotifyLastUsed(context)
        }
        SoundManager.playPaste()

        dismiss()
        previousApp = nil

        if let app = appToRestore {
            app.activate()
            clipboardManager.simulatePaste(forceNewLine: addNewLine)
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
        panel.level = .floating
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

        let hostingView = hosting.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
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
        self.level = .floating + 1
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
