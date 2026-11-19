import CoreGraphics

/// 贴边条的摆放计算。纯逻辑，不碰窗口和 AX，方便单测。
///
/// 坐标一律是 AppKit 屏幕坐标：原点在主屏左下角，y 向上。
enum ShelfPlacement {
    enum Dock: Equatable {
        case top
        case bottom
    }

    /// 条的左右两边离屏幕可用区域的距离
    static let horizontalMargin: CGFloat = 10
    /// 条离所贴那条边（程序坞上沿 / 菜单栏下沿）的距离
    static let edgeGap: CGFloat = 8
    /// 宽屏上不铺满：超过这个宽度就居中限宽，免得看一遍要横扫整块屏幕
    static let maxWidth: CGFloat = 1800
    /// 条的高度：顶栏 44 + 卡片区 170（上下留白 8 + 10，卡片 152）。第一期固定，不支持拖动调整
    static let height: CGFloat = 214

    /// 输入位置离条的上沿不到这么远，也算会被挡住：光标贴着条边很难看清
    static let coverMargin: CGFloat = 24

    /// 决定贴哪条边。「自动」默认贴底；贴底会挡住输入位置时改贴顶。
    /// - Parameter anchor: 光标位置；读不到光标时是输入框中心或鼠标位置；全都没有时为 nil。
    static func dock(preference: QuickPanelShelfEdge, anchor: CGPoint?, visibleFrame: CGRect) -> Dock {
        switch preference {
        case .bottom:
            return .bottom
        case .top:
            return .top
        case .auto:
            guard let anchor else { return .bottom }
            let bottomFrame = frame(dock: .bottom, height: height, visibleFrame: visibleFrame)
            return anchor.y <= bottomFrame.maxY + coverMargin ? .top : .bottom
        }
    }

    /// 贴边条窗口的 frame。
    static func frame(dock: Dock, height: CGFloat, visibleFrame: CGRect) -> CGRect {
        let width = min(visibleFrame.width - horizontalMargin * 2, maxWidth).rounded()
        let x = (visibleFrame.midX - width / 2).rounded()
        let y: CGFloat = switch dock {
        case .bottom: visibleFrame.minY + edgeGap
        case .top: visibleFrame.maxY - edgeGap - height
        }
        return CGRect(x: x, y: y.rounded(), width: width, height: height)
    }
}
