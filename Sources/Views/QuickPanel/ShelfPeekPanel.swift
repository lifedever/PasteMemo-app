import AppKit
import SwiftUI

/// 贴边条的预览浮窗：选中卡片的完整内容，朝屏幕中间展开——贴底时在条上方，贴顶时在下方，
/// 水平对着选中卡片。
///
/// 放在独立窗口里：条只有 214pt 高，预览要比条大得多，只能放到条外面。它不抢键盘，按键
/// 都还在快捷面板里处理（←→ 换卡片时预览跟着换、朝屏幕边缘的方向键收起），只接收滚动，
/// 长内容可以滚着看。外观和面板本体同一套：背后模糊 + 染色层 + 1px 细线 + 自绘散射投影。
@MainActor
final class ShelfPeekPanel {
    static let shared = ShelfPeekPanel()

    private static let width: CGFloat = 560
    private static let maxHeight: CGFloat = 420
    private static let minHeight: CGFloat = 160
    /// 浮窗和条之间的空隙
    private static let gap: CGFloat = 10
    private static let cornerRadius: CGFloat = 14

    private var panel: NSPanel?
    private var shadowPanel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    /// 焦点卡片在条窗口里的位置（AppKit 窗口坐标）。条从屏幕外滑进来，屏幕坐标要到显示时才换算
    private var cardInWindow: CGRect = .zero

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    func updateAnchor(cardInWindow: CGRect) {
        self.cardInWindow = cardInWindow
    }

    func show<Content: View>(content: Content, parent: NSWindow, dock: ShelfPlacement.Dock) {
        guard cardInWindow != .zero else { return }
        let card = parent.convertToScreen(cardInWindow)
        let shelf = parent.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(shelf) } ?? parent.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? shelf

        // 朝屏幕中间那一侧还剩多少高度
        let room = dock == .bottom
            ? visible.maxY - shelf.maxY - Self.gap * 2
            : shelf.minY - visible.minY - Self.gap * 2
        let height = min(Self.maxHeight, max(Self.minHeight, room))
        let width = min(Self.width, visible.width - 24)
        let x = min(max(card.midX - width / 2, visible.minX + 12), visible.maxX - width - 12)
        let y = dock == .bottom ? shelf.maxY + Self.gap : shelf.minY - Self.gap - height
        let frame = NSRect(x: x, y: y, width: width, height: height)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = self.hosting ?? makeHosting(in: panel)
        self.hosting = hosting
        hosting.rootView = AnyView(content)

        let shadowPanel = self.shadowPanel ?? DiffuseShadow.makePanel(level: parent.level)
        self.shadowPanel = shadowPanel
        let shadowFrame = frame.insetBy(dx: -DiffuseShadow.pad, dy: -DiffuseShadow.pad)
        if shadowPanel.frame.size != shadowFrame.size {
            shadowPanel.contentView = DiffuseShadow.makeView(size: shadowFrame.size, cornerRadius: Self.cornerRadius, contactLineInDark: true)
        }
        shadowPanel.setFrame(shadowFrame, display: false)
        panel.setFrame(frame, display: true)

        // 挂成条的子窗口：条关掉时一起关。对子窗口 orderOut 会把它从父窗口摘掉，所以每次都检查
        panel.level = parent.level
        shadowPanel.level = parent.level
        if shadowPanel.parent == nil { parent.addChildWindow(shadowPanel, ordered: .above) }
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        shadowPanel.orderFront(nil)
        panel.order(.above, relativeTo: shadowPanel.windowNumber)
    }

    func hide() {
        guard let panel, panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let shadowPanel {
            shadowPanel.parent?.removeChildWindow(shadowPanel)
            shadowPanel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = PeekPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = PanelHostView(frame: .zero)
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.autoresizingMask = [.width, .height]

        let blur = NSVisualEffectView(frame: .zero)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)

        let tint = PanelTintView(frame: .zero)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        container.addSubview(tint)

        panel.contentView = container
        return panel
    }

    private func makeHosting(in panel: NSPanel) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.autoresizingMask = [.width, .height]
        if let container = panel.contentView {
            hosting.frame = container.bounds
            container.addSubview(hosting)
        }
        return hosting
    }
}

/// 预览浮窗不拿键盘：按键一律留在快捷面板里处理
private final class PeekPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
