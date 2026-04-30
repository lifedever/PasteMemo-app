import AppKit
import SwiftUI

private let MIN_WIDTH: CGFloat = 320
private let MAX_WIDTH: CGFloat = 800
private let DEFAULT_WIDTH: CGFloat = 320
private let SCREEN_MARGIN: CGFloat = 16
private let MAX_HEIGHT: CGFloat = 500
private let HANDLE_WIDTH: CGFloat = 8
private let WIDTH_PREF_KEY = "relayPanelWidth"

@MainActor
final class RelayFloatingWindowController {

    static let MAX_VISIBLE_ROWS = 12

    private var window: NSPanel?
    private var closeDelegate: WindowCloseDelegate?
    private var hostingController: NSHostingController<AnyView>?
    private let relayManager: RelayManager
    private var sizeObservation: NSKeyValueObservation?
    private var resizeObserver: Any?

    init(relayManager: RelayManager) {
        self.relayManager = relayManager
    }

    func show() {
        guard window == nil else { return }

        let storedWidth = UserDefaults.standard.double(forKey: WIDTH_PREF_KEY)
        let initialWidth = storedWidth > 0
            ? min(max(storedWidth, MIN_WIDTH), MAX_WIDTH)
            : DEFAULT_WIDTH

        // Wrap content so width tracks @AppStorage("relayPanelWidth") set by the resize handle.
        let content = RelayPanelWidthWrapper(manager: relayManager)
        let hosting = NSHostingController(
            rootView: AnyView(content.ignoresSafeArea().modelContainer(PasteMemoApp.sharedModelContainer))
        )
        hosting.sizingOptions = .preferredContentSize
        hostingController = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 200),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: MIN_WIDTH, height: 100)
        panel.maxSize = NSSize(width: MAX_WIDTH, height: CGFloat.greatestFiniteMagnitude)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true

        let container = HoverTrackingContainerView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: 200))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        let visualEffect = NSVisualEffectView(frame: container.bounds)
        visualEffect.material = .windowBackground
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

        // Container 自己驱动 cursor + 拖拽：不挂 sibling 子视图，避免和 SwiftUI 行的
        // .onHover tracking area 重叠互抢事件（之前左侧 handle 永久亮 + 光标不切换的根因）。
        // SwiftUI 内容继续 edge-to-edge 显示，靠 container 在 mouseDown 拦截边缘点击实现 resize。
        container.handleWidth = HANDLE_WIDTH
        container.onResize = { [weak panel] newWidth, edge in
            guard let panel else { return }
            var frame = panel.frame
            switch edge {
            case .left:
                let rightEdge = frame.maxX
                frame.size.width = newWidth
                frame.origin.x = rightEdge - newWidth
            case .right:
                frame.size.width = newWidth
            }
            panel.setFrame(frame, display: true, animate: false)
            UserDefaults.standard.set(Double(newWidth), forKey: WIDTH_PREF_KEY)
        }
        container.minWidth = MIN_WIDTH
        container.maxWidth = MAX_WIDTH
        container.installIndicators()

        panel.contentView = container

        let delegate = WindowCloseDelegate { [weak self] in
            self?.relayManager.deactivate()
        }
        panel.delegate = delegate
        closeDelegate = delegate

        // Observe preferredContentSize changes from SwiftUI
        sizeObservation = hosting.observe(\.preferredContentSize, options: [.new, .initial]) { [weak self] controller, _ in
            Task { @MainActor in
                self?.resizeToFit(controller.preferredContentSize)
            }
        }

        positionTopRight(panel, height: 200)
        panel.orderFrontRegardless()
        self.window = panel

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let win = self.window else { return }
                let w = min(max(win.frame.size.width, MIN_WIDTH), MAX_WIDTH)
                UserDefaults.standard.set(Double(w), forKey: WIDTH_PREF_KEY)
                // 不贴右上：会话内保持用户拖到的位置；resizeToFit 已经做 top-anchored grow，
                // 内容增减时窗口的顶部相对位置不变，跟着内容向下生长 / 收缩即可。
            }
        }
    }

    func dismiss() {
        sizeObservation?.invalidate()
        sizeObservation = nil
        if let obs = resizeObserver {
            NotificationCenter.default.removeObserver(obs)
            resizeObserver = nil
        }
        window?.close()
        window = nil
        closeDelegate = nil
        hostingController = nil
    }

    private func pinTopRight(_ panel: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = visible.maxX - frame.size.width - SCREEN_MARGIN
        frame.origin.y = visible.maxY - frame.size.height - SCREEN_MARGIN
        panel.setFrame(frame, display: true, animate: false)
    }

    func updateSize(for itemCount: Int) {
        // No-op: sizing is now driven by SwiftUI content via preferredContentSize
    }

    private func resizeToFit(_ contentSize: NSSize) {
        guard let panel = window else { return }
        let newHeight = min(contentSize.height, MAX_HEIGHT)
        let delta = newHeight - panel.frame.height
        // Ignore sub-pixel noise (SwiftUI reports fractional sizes mid-animation).
        guard abs(delta) > 1 else { return }

        var frame = panel.frame
        frame.origin.y -= delta
        frame.size.height = newHeight

        // AppKit handles smooth frame interpolation natively with animate: true —
        // one animation source means SwiftUI content stays at its final layout
        // while NSWindow grows/shrinks around it. Hero (top-anchored) stays put.
        panel.setFrame(frame, display: true, animate: true)
    }

    private func positionTopRight(_ panel: NSPanel, height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.maxX - panel.frame.size.width - SCREEN_MARGIN
        let y = visibleFrame.maxY - height - SCREEN_MARGIN
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

/// Container view that owns BOTH the window-wide hover tracking AND the
/// edge-resize cursor / drag interaction. Driving everything from the container
/// (instead of sibling handle subviews) avoids tracking-area collisions with
/// SwiftUI's own `.onHover` regions inside the hosted content.
private final class HoverTrackingContainerView: NSView {
    enum Edge { case left, right }

    var handleWidth: CGFloat = 8
    var minWidth: CGFloat = 320
    var maxWidth: CGFloat = 800
    var onResize: ((CGFloat, Edge) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isWindowHovered = false { didSet { updateIndicators() } }
    private var hoveredEdge: Edge? {
        didSet {
            updateIndicators()
            // SwiftUI 的 NSHostingView 会在 mouseMoved 中重置光标为箭头，普通 NSCursor.set 抢不过它。
            // push/pop 把 resize 光标压到全局栈顶，离开边缘再 pop 还原。
            if hoveredEdge != nil, oldValue == nil {
                NSCursor.resizeLeftRight.push()
            } else if hoveredEdge == nil, oldValue != nil {
                NSCursor.pop()
            }
        }
    }
    private var dragEdge: Edge?
    private var dragStartWidth: CGFloat = 0
    private var dragStartScreenX: CGFloat = 0

    private let leftIndicator = HoverTrackingContainerView.makeIndicator()
    private let rightIndicator = HoverTrackingContainerView.makeIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    required init?(coder: NSCoder) { nil }

    /// 在所有内容子视图（visualEffect / hostingView）添加完后调用，把指示条提到 z-order 顶部。
    func installIndicators() {
        addSubview(leftIndicator)
        addSubview(rightIndicator)
        NSLayoutConstraint.activate([
            leftIndicator.widthAnchor.constraint(equalToConstant: 3),
            leftIndicator.heightAnchor.constraint(equalToConstant: 36),
            leftIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),

            rightIndicator.widthAnchor.constraint(equalToConstant: 3),
            rightIndicator.heightAnchor.constraint(equalToConstant: 36),
            rightIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
    }

    private static func makeIndicator() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        v.layer?.cornerRadius = 1.5
        v.alphaValue = 0
        return v
    }

    private func updateIndicators() {
        // 三档：贴边悬浮/拖拽 → 高亮；只在窗口里 → 淡显；都不在 → 隐藏。
        // 把动画时长拉长到 0.18s 让淡入淡出更柔和。
        let leftTarget: CGFloat = (dragEdge == .left || hoveredEdge == .left) ? 0.65
            : (isWindowHovered ? 0.28 : 0)
        let rightTarget: CGFloat = (dragEdge == .right || hoveredEdge == .right) ? 0.65
            : (isWindowHovered ? 0.28 : 0)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            leftIndicator.animator().alphaValue = leftTarget
            rightIndicator.animator().alphaValue = rightTarget
        }
    }

    // MARK: - Tracking + cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isWindowHovered = true
        updateEdgeFor(point: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        isWindowHovered = false
        hoveredEdge = nil
    }
    override func mouseMoved(with event: NSEvent) {
        updateEdgeFor(point: convert(event.locationInWindow, from: nil))
    }
    override func cursorUpdate(with event: NSEvent) {
        if hoveredEdge != nil {
            NSCursor.resizeLeftRight.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    private func updateEdgeFor(point: NSPoint) {
        let edge: Edge?
        if point.x < handleWidth { edge = .left }
        else if point.x > bounds.width - handleWidth { edge = .right }
        else { edge = nil }
        if edge != hoveredEdge { hoveredEdge = edge }
    }

    // MARK: - Drag-to-resize (only when click lands in edge zone)

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 只在边缘 8px 内 claim 点击;中间区域让给 SwiftUI 内容正常交互。
        let local = convert(point, from: superview)
        if local.x < handleWidth || local.x > bounds.width - handleWidth {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        if local.x < handleWidth { dragEdge = .left }
        else if local.x > bounds.width - handleWidth { dragEdge = .right }
        else { dragEdge = nil; return }
        dragStartWidth = window.frame.size.width
        dragStartScreenX = NSEvent.mouseLocation.x
        updateIndicators()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let edge = dragEdge else { return }
        let currentX = NSEvent.mouseLocation.x
        let delta = (edge == .left) ? (dragStartScreenX - currentX) : (currentX - dragStartScreenX)
        var newWidth = dragStartWidth + delta
        newWidth = min(max(newWidth, minWidth), maxWidth)
        onResize?(newWidth, edge)
    }

    override func mouseUp(with event: NSEvent) {
        dragEdge = nil
        updateIndicators()
    }
}

// MARK: - Width-tracking wrapper

private struct RelayPanelWidthWrapper: View {
    let manager: RelayManager
    @AppStorage("relayPanelWidth") private var panelWidth: Double = 320

    var body: some View {
        let w = min(max(panelWidth, 320), 800)
        RelayQueueView(manager: manager)
            .frame(width: w)
    }
}
