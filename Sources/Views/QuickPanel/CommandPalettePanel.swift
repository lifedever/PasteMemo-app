import AppKit
import SwiftUI

/// ⌘K 快捷操作菜单的独立浮窗。
///
/// 为什么不是面板内的 SwiftUI overlay：overlay 画在面板视图树里，必然被窗口边界
/// 裁掉。而菜单的定位原则是「左边缘不压住列表条目」，于是
///   - 窄窗口（无预览区）：列表铺满宽度，菜单必然整个落在窗口外
///   - 宽窗口：菜单比预览区宽时，也有一部分落在窗口外
/// 两种情况都要求能越过边界，只有独立窗口做得到。
///
/// 附带解决了另一个死结：菜单高度接近面板高度时，窗口内没有垂直活动空间，
/// clamp 会把它一路顶到面板顶部、看着完全不跟随选中行；屏幕比面板高得多，
/// 挪到屏幕坐标系里就有地方可去了。
@MainActor
final class CommandPalettePanel {
    static let shared = CommandPalettePanel()

    private var panel: NSPanel?
    private var onDismiss: (() -> Void)?

    /// 锚点（屏幕坐标）存在这里而不是 SwiftUI 的 @State：@State 赋值不会在同一个
    /// 调用栈里生效，而上报和「⌘K 打开」两条路径会在同一轮里先后调用定位，用 @State
    /// 必然有一条读到上一轮的旧坐标，把另一条算对的位置覆盖掉。
    private(set) var anchorRow: CGRect = .zero
    private(set) var anchorList: CGRect = .zero

    func updateAnchor(row: CGRect, list: CGRect) {
        anchorRow = row
        anchorList = list
    }
    /// 窗口比内容大出的一圈，用来容纳 SwiftUI 画的投影——不留这圈投影会被窗口
    /// 边界直接裁掉。
    private static let shadowPad: CGFloat = 40

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    /// 显示菜单。`rowOnScreen` / `listOnScreen` 均为屏幕坐标（AppKit 原点在左下）。
    func show<Content: View>(
        content: Content,
        width: CGFloat,
        maxHeight: CGFloat,
        parent: NSWindow,
        onDismiss: @escaping () -> Void
    ) {
        let rowOnScreen = anchorRow
        let listOnScreen = anchorList
        self.onDismiss = onDismiss

        // 先量内容本身的高度（不带投影留白）。fittingSize 在 macOS 15/26 上不可信
        // ——配 sizingOptions = [] 尤其容易返回 0，窗口就成了 0×0、什么都看不见——
        // 所以钉死宽度、给足高度让它布局完再读，并做理智 clamp。
        let probe = NSHostingView(rootView: AnyView(content))
        probe.sizingOptions = []
        probe.frame = NSRect(x: 0, y: 0, width: width, height: maxHeight)
        probe.layoutSubtreeIfNeeded()
        var measured = probe.fittingSize.height
        if !(measured.isFinite) || measured < 40 || measured > maxHeight {
            measured = maxHeight
        }
        let contentSize = NSSize(width: width, height: measured)

        // 投影画在 SwiftUI 里，不用 NSPanel.hasShadow：透明背景的 borderless 窗口
        // 上系统投影经常不出现，或者按窗口矩形而非圆角形状绘制。代价是窗口要比内容
        // 大出 SHADOW_PAD 一圈来容纳投影，定位时再把这圈补偿回去。
        let hosting = NSHostingView(rootView: AnyView(
            content
                .shadow(color: .black.opacity(0.28), radius: 24, y: 8)
                .padding(Self.shadowPad)
        ))
        hosting.sizingOptions = []

        let contentFrame = frameFor(size: contentSize, rowOnScreen: rowOnScreen, listOnScreen: listOnScreen)
        let frame = contentFrame.insetBy(dx: -Self.shadowPad, dy: -Self.shadowPad)

        let panel = self.panel ?? makePanel()
        panel.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        panel.setFrame(frame, display: true)

        if panel.parent == nil {
            // 作为子窗口挂上去：主面板移动/关闭时自动跟随，不用自己监听。
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        self.panel = panel
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        // contentView 留着会让 SwiftUI 视图树一直活着（键盘 monitor 也不释放）
        panel.contentView = nil
        self.panel = nil
        onDismiss = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            // nonactivatingPanel：菜单不抢 key，主面板保持焦点，搜索框和方向键
            // 才还能继续工作（CommandPaletteContent 用的是全局事件 monitor）。
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // 投影由 SwiftUI 画（见 show），系统投影在透明 borderless 窗口上不可靠
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// 定位规则：左边缘贴列表右边缘（绝不压住条目），顶部对齐选中行；
    /// 右侧/下方超出屏幕可视区时再往回收。
    private func frameFor(size: NSSize, rowOnScreen: CGRect, listOnScreen: CGRect) -> NSRect {
        let gap: CGFloat = 8
        let screen = NSScreen.screens.first { $0.frame.intersects(rowOnScreen) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var x = listOnScreen.maxX + gap
        // 右边放不下就翻到列表左侧外面，仍然不压条目
        if x + size.width > visible.maxX - gap {
            let flipped = listOnScreen.minX - size.width - gap
            x = flipped >= visible.minX + gap ? flipped : (visible.maxX - size.width - gap)
        }

        // AppKit 屏幕坐标原点在左下：顶部对齐选中行 = 菜单 maxY 对齐行 maxY。
        // 往下装不下时**翻转成向上展开**（菜单底边对齐行底边），而不是硬 clamp——
        // 硬 clamp 会把菜单一路推到屏幕边上，看着完全不跟随选中行，选底部条目时
        // 尤其明显。这也是原生菜单碰到屏幕边缘的行为。
        var y = rowOnScreen.maxY - size.height
        if y < visible.minY + gap {
            y = rowOnScreen.minY
        }
        // 两个方向都装不下（菜单比可用高度还高）才贴边
        if y + size.height > visible.maxY - gap { y = visible.maxY - size.height - gap }
        if y < visible.minY + gap { y = visible.minY + gap }

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
