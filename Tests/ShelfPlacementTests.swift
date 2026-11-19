import CoreGraphics
import Testing
@testable import PasteMemo

/// 贴边条的摆放：贴哪条边、窗口 frame。坐标是 AppKit 屏幕坐标（y 向上）。
@Suite("Shelf placement")
struct ShelfPlacementTests {
    /// 1512×982 的笔记本屏幕，扣掉菜单栏 33 和程序坞 70 之后的可用区域
    private let visible = CGRect(x: 0, y: 70, width: 1512, height: 879)

    @Test("自动：贴底会挡住输入位置时贴顶")
    func autoCoveredCaretDocksTop() {
        // 贴底时条占 y 78–292，光标在 150，会被挡住
        let dock = ShelfPlacement.dock(preference: .auto, anchor: CGPoint(x: 600, y: 150), visibleFrame: visible)
        #expect(dock == .top)
    }

    @Test("自动：输入位置在上方，默认贴底")
    func autoCaretHighDocksBottom() {
        let dock = ShelfPlacement.dock(preference: .auto, anchor: CGPoint(x: 600, y: 800), visibleFrame: visible)
        #expect(dock == .bottom)
    }

    @Test("自动：输入位置在下半屏但条挡不到，仍然贴底")
    func autoLowerHalfButClearDocksBottom() {
        // 屏幕中线约 509，光标在 400：下半屏，但离条的上沿（292）还远
        let dock = ShelfPlacement.dock(preference: .auto, anchor: CGPoint(x: 600, y: 400), visibleFrame: visible)
        #expect(dock == .bottom)
    }

    @Test("自动：离条的上沿不到 24pt 也算挡住")
    func autoCoverMarginBoundary() {
        let edge = ShelfPlacement.frame(dock: .bottom, height: ShelfPlacement.height, visibleFrame: visible).maxY
        let margin = ShelfPlacement.coverMargin
        #expect(ShelfPlacement.dock(preference: .auto, anchor: CGPoint(x: 600, y: edge + margin), visibleFrame: visible) == .top)
        #expect(ShelfPlacement.dock(preference: .auto, anchor: CGPoint(x: 600, y: edge + margin + 1), visibleFrame: visible) == .bottom)
    }

    @Test("自动：什么都读不到时贴底")
    func autoWithoutAnchorDocksBottom() {
        #expect(ShelfPlacement.dock(preference: .auto, anchor: nil, visibleFrame: visible) == .bottom)
    }

    @Test("固定位置不看光标")
    func fixedPreferenceIgnoresAnchor() {
        let low = CGPoint(x: 600, y: 100)
        let high = CGPoint(x: 600, y: 900)
        #expect(ShelfPlacement.dock(preference: .bottom, anchor: low, visibleFrame: visible) == .bottom)
        #expect(ShelfPlacement.dock(preference: .top, anchor: high, visibleFrame: visible) == .top)
    }

    @Test("副屏：按副屏自己的可用区域判断")
    func secondaryScreenUsesItsOwnFrame() {
        // 主屏右边一块 1920×1080 的外接屏，可用区域扣掉菜单栏；贴底时条的上沿在 124
        let external = CGRect(x: 1512, y: -98, width: 1920, height: 1055)
        #expect(ShelfPlacement.dock(preference: .auto, anchor: CGPoint(x: 2000, y: 100), visibleFrame: external) == .top)
        #expect(ShelfPlacement.dock(preference: .auto, anchor: CGPoint(x: 2000, y: 300), visibleFrame: external) == .bottom)
    }

    @Test("贴底：两边留边距，底边离程序坞一个间隙")
    func bottomFrame() {
        let frame = ShelfPlacement.frame(dock: .bottom, height: 236, visibleFrame: visible)
        #expect(frame == CGRect(x: 10, y: 78, width: 1492, height: 236))
    }

    @Test("贴顶：顶边离菜单栏一个间隙")
    func topFrame() {
        let frame = ShelfPlacement.frame(dock: .top, height: 236, visibleFrame: visible)
        #expect(frame.maxY == visible.maxY - ShelfPlacement.edgeGap)
        #expect(frame.minX == 10)
    }

    @Test("宽屏限宽并居中")
    func wideScreenCapsWidthAndCenters() {
        let ultrawide = CGRect(x: 0, y: 0, width: 3440, height: 1400)
        let frame = ShelfPlacement.frame(dock: .bottom, height: 236, visibleFrame: ultrawide)
        #expect(frame.width == ShelfPlacement.maxWidth)
        #expect(frame.midX == ultrawide.midX)
    }
}
