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
///
/// 玻璃与投影，三条规则全部是 macOS 26.6 上实测出来的：
///   - 卡片必须是 key window。非 key 时 `.glassEffect` 在这个子窗口里只有主面板第二次
///     及以后打开才活，首次打开永远是一块平灰、没有边缘高光（就是「⌘K 弹出来是灰的，
///     点一下条目才变玻璃」）；成为 key 后首次打开就正常（剖面边缘 249→246 的高光
///     梯度）。它是 nonactivating 面板，makeKey 不会激活 App；菜单键盘事件走本地
///     monitor、不依赖 key 状态；关闭时把 key 还给主面板。
///   - 投影不能画在卡片窗口里。SwiftUI `.shadow` 套在玻璃上会把子树离屏光栅化、背景
///     采样失效，卡片退化成实色。系统窗口投影（hasShadow）能用，但它贴着边缘有一圈
///     深色接触线，小卡片上看着就是一道边框。
///   - 投影画在另一个透明子窗口里：shadowPath 散射 + 奇偶遮罩掏空卡片内部，卡片窗口
///     里只剩玻璃宿主视图。效果就是 Raycast / 系统通知那种柔和散射、无边线。
@MainActor
final class CommandPalettePanel {
    static let shared = CommandPalettePanel()

    private var panel: NSPanel?
    /// 只画投影的透明子窗口，垫在卡片窗口下面。系统窗口投影贴着边缘有一圈深色
    /// 接触线，小卡片上看着就是一道边框；自己画的散射没有这条线。
    private var shadowPanel: NSPanel?
    private var onDismiss: (() -> Void)?
    private var occlusionObserver: NSObjectProtocol?
    /// 投影窗口比卡片大出的一圈，容纳投影的散射范围。
    private static let shadowPad: CGFloat = DiffuseShadow.pad
    private static let cornerRadius: CGFloat = 16

    /// 主面板的 resignKey 监听用它判断「key 是被自家菜单拿走的」，不当成用户点了别处。
    var panelWindow: NSWindow? { panel }

    /// 锚点（屏幕坐标）存在这里而不是 SwiftUI 的 @State：@State 赋值不会在同一个
    /// 调用栈里生效，而上报和「⌘K 打开」两条路径会在同一轮里先后调用定位，用 @State
    /// 必然有一条读到上一轮的旧坐标，把另一条算对的位置覆盖掉。
    private(set) var anchorRow: CGRect = .zero
    private(set) var anchorList: CGRect = .zero
    private var resignKeyObserver: NSObjectProtocol?

    func updateAnchor(row: CGRect, list: CGRect) {
        anchorRow = row
        anchorList = list
    }
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

        // 先量内容本身的高度，窗口必须和卡片一样高：窗口比卡片高出的那截在 key
        // 窗口里会被铺上玻璃底，看着像卡片下面多出一块。
        // 必须用 intrinsicContentSize：sizingOptions = [] 时 fittingSize 恒为 0，
        // 之前被 clamp 成 maxHeight，窗口永远是上限高度（卡片矮的条目就露馅）。
        let probe = NSHostingView(rootView: AnyView(content))
        probe.sizingOptions = [.intrinsicContentSize]
        probe.frame = NSRect(x: 0, y: 0, width: width, height: maxHeight)
        probe.layoutSubtreeIfNeeded()
        var measured = probe.intrinsicContentSize.height
        if !(measured.isFinite) || measured < 40 || measured > maxHeight {
            measured = maxHeight
        }
        let contentSize = NSSize(width: width, height: measured)

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.sizingOptions = []
        // 窗口没有标题栏可言，安全区整个关掉，卡片从窗口顶部铺起
        hosting.safeAreaRegions = []
        // key 窗口里宿主视图的整块矩形会被铺上一层极淡的玻璃底，圆角外的四个角
        // 会露出尖角。按卡片圆角把宿主视图裁掉，主面板的 glassHost 就是这么做的。
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = Self.cornerRadius
        hosting.layer?.masksToBounds = true

        let frame = frameFor(size: contentSize, rowOnScreen: rowOnScreen, listOnScreen: listOnScreen, parentFrame: parent.frame)

        // 投影窗口先挂、先 orderFront，卡片窗口随后压在它上面。两个都是主面板的
        // 子窗口，面板移动/关闭时自动跟随。
        let shadowFrame = frame.insetBy(dx: -Self.shadowPad, dy: -Self.shadowPad)
        let shadowPanel = self.shadowPanel ?? makeShadowPanel()
        shadowPanel.contentView = Self.makeShadowView(size: shadowFrame.size)
        shadowPanel.setFrame(shadowFrame, display: false)
        // 投影比卡片早约 40ms 上屏（卡片内容要等窗口合成完再挂），先隐着，和卡片
        // 一起在 present 里淡入，否则会先闪出一圈没有卡片的影子。
        shadowPanel.alphaValue = 0
        if shadowPanel.parent == nil {
            parent.addChildWindow(shadowPanel, ordered: .above)
        }
        shadowPanel.orderFront(nil)
        self.shadowPanel = shadowPanel

        let panel = self.panel ?? makePanel()
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        panel.setFrame(frame, display: false)
        if panel.parent == nil {
            // 作为子窗口挂上去：主面板移动/关闭时自动跟随，不用自己监听。
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.order(.above, relativeTo: shadowPanel.windowNumber)
        attachContent(hosting, to: panel)
        self.panel = panel

        QuickPanelWindowController.shared.setPaletteHoldsKey(true)
        if resignKeyObserver == nil {
            // 卡片把 key 丢给了别的窗口（用户点了别的 App）：主面板此时拒绝成为 key、
            // 收不到自己的 didResignKey，替它走一遍同样的失焦逻辑。
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
            ) { [weak panel] _ in
                guard let panel, let parent = panel.parent, NSApp.keyWindow !== parent else { return }
                QuickPanelWindowController.shared.handleResignKey()
            }
        }
    }

    /// 投影视图与投影窗口的做法见 DiffuseShadow，主面板共用。
    private static func makeShadowView(size: NSSize) -> NSView {
        DiffuseShadow.makeView(size: size, cornerRadius: cornerRadius)
    }

    private func makeShadowPanel() -> NSPanel {
        DiffuseShadow.makePanel(level: .statusBar + 1)
    }

    /// 玻璃内容等窗口真正被窗口服务器合成之后再挂上去：新建的窗口在 `orderFront`
    /// 刚返回时 occlusionState 还不含 .visible，约 40ms 后才变。
    private func attachContent(_ hosting: NSView, to panel: NSPanel) {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if panel.occlusionState.contains(.visible) {
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let panel else { return }
                self?.present(hosting, in: panel)
            }
            return
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            guard let panel, panel.occlusionState.contains(.visible) else { return }
            if let obs = self?.occlusionObserver {
                NotificationCenter.default.removeObserver(obs)
                self?.occlusionObserver = nil
            }
            self?.present(hosting, in: panel)
        }
    }

    /// 玻璃采样期：内容挂上后先在全透明状态停这么久再开始淡入。玻璃第一帧按外观
    /// 画一版、背景采样回来才变成真玻璃，中间差一两帧；淡入从 0 起步的话文字会先于
    /// 玻璃被看到，卡片和内容像是分两次出现。两帧（约 33ms）够采样完成。
    private static let glassSettleDelay: TimeInterval = 0.035

    /// 挂上内容并做一个短促的入场：窗口透明度 0→1 加内容层 0.96→1 的缩放，120ms
    /// easeOut。透明度走窗口服务器、缩放只动图层 transform，都不会把玻璃拖进离屏
    /// 渲染。透明度在同一轮里先归零再挂内容，中间不会画出一帧全亮的卡片。
    private func present(_ hosting: NSView, in panel: NSPanel) {
        panel.alphaValue = 0
        shadowPanel?.alphaValue = 0
        panel.contentView = hosting
        hosting.wantsLayer = true
        if let layer = hosting.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let bounds = hosting.bounds
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            layer.transform = CATransform3DMakeScale(0.96, 0.96, 1)
            CATransaction.commit()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.glassSettleDelay) { [weak self, weak panel, weak hosting] in
            // 停留期间被收起了就不动画（hide 已把 contentView 置空）
            guard let panel, let hosting, panel.contentView === hosting else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                self?.shadowPanel?.animator().alphaValue = 1
            }
            if let layer = hosting.layer {
                let anim = CABasicAnimation(keyPath: "transform")
                anim.fromValue = CATransform3DMakeScale(0.96, 0.96, 1)
                anim.toValue = CATransform3DIdentity
                anim.duration = 0.12
                anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(anim, forKey: "present")
                layer.transform = CATransform3DIdentity
            }
        }
    }

    func hide() {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        if let shadowPanel {
            shadowPanel.parent?.removeChildWindow(shadowPanel)
            shadowPanel.orderOut(nil)
            shadowPanel.contentView = nil
            self.shadowPanel = nil
        }
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.alphaValue = 1
        // contentView 留着会让 SwiftUI 视图树一直活着（键盘 monitor 也不释放）
        panel.contentView = nil
        self.panel = nil
        onDismiss = nil
        // 恢复主面板的 key 资格并把 key 还回去（主面板已收起时它内部会跳过 makeKey）
        QuickPanelWindowController.shared.setPaletteHoldsKey(false)
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePalettePanel(
            contentRect: .zero,
            // nonactivatingPanel：不激活 App。canBecomeKey 由子类放开，见类注释。
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // 只需高过主面板（.statusBar）一层
        panel.level = .statusBar + 1
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // 投影由独立子窗口画（见 show），系统投影贴边有一圈深色接触线
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// 主面板底栏占的高度：卡片底边不越过它。卡片压在底栏胶囊（也是玻璃）上时，
    /// 两块玻璃跨窗口叠合会在卡片下沿渲染出一条方角的玻璃底，看着像卡片多出一块。
    private static let parentFooterInset: CGFloat = 56

    /// 定位规则：左边缘贴列表右边缘（绝不压住条目），顶部对齐选中行；
    /// 垂直方向优先留在主面板内部、底栏之上，装不下时才放到整块屏幕里去。
    private func frameFor(size: NSSize, rowOnScreen: CGRect, listOnScreen: CGRect, parentFrame: CGRect) -> NSRect {
        let gap: CGFloat = 8
        let screen = NSScreen.screens.first { $0.frame.intersects(rowOnScreen) }
            ?? NSScreen.main
        let screenVisible = screen?.visibleFrame ?? .zero
        // 装得下就以「主面板去掉底栏」为边界；装不下（动作很多、面板很矮）再退到
        // 屏幕可视区，否则卡片会被硬顶到面板顶部、完全不跟随选中行。
        var parentBounds = parentFrame
        parentBounds.origin.y += Self.parentFooterInset
        parentBounds.size.height -= Self.parentFooterInset
        let fitsInParent = size.height + 2 * gap <= parentBounds.height
        let visible = fitsInParent ? parentBounds : screenVisible

        var x = listOnScreen.maxX + gap
        // 右边放不下就翻到列表左侧外面，仍然不压条目
        if x + size.width > visible.maxX - gap {
            let flipped = listOnScreen.minX - size.width - gap
            x = flipped >= visible.minX + gap ? flipped : (visible.maxX - size.width - gap)
        }

        // AppKit 屏幕坐标原点在左下：顶部对齐选中行 = 菜单 maxY 对齐行 maxY。
        var y = rowOnScreen.maxY - size.height
        if fitsInParent {
            // 面板内只往上滑到装得下为止，不翻转：面板比卡片高不了多少，翻转会把
            // 卡片一路顶到面板顶部、盖住搜索框和标签栏。
            if y < visible.minY + gap { y = visible.minY + gap }
            if y + size.height > visible.maxY - gap { y = visible.maxY - size.height - gap }
        } else {
            // 屏幕范围里装不下时**翻转成向上展开**（菜单底边对齐行底边），而不是硬
            // clamp——硬 clamp 会把菜单一路推到屏幕边上、完全不跟随选中行。这也是
            // 原生菜单碰到屏幕边缘的行为。两个方向都装不下才贴边。
            if y < visible.minY + gap { y = rowOnScreen.minY }
            if y + size.height > visible.maxY - gap { y = visible.maxY - size.height - gap }
            if y < visible.minY + gap { y = visible.minY + gap }
        }

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// 无边框面板默认拒绝成为 key；放开它，玻璃才能在首次打开时就正常渲染（见类注释）。
private final class KeyablePalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
