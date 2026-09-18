import Foundation
import Testing
@testable import PasteMemo

/// 快捷面板里对没识别过的图片按 G（粘贴 OCR 文字）：面板先关，识别在后台跑完才发 ⌘V。
/// 文档识别引擎整机首次调用要加载模型（实测同一张图首次 48s、之后 0.1s 上下），慢路径
/// 下用户早切走了，仍朝当初记下的进程投 ⌘V 会把文字粘进看不见的窗口——用户报的
/// 「按了完全没反应，等多久都不出现」就是这么来的。
@Suite("On-demand OCR paste routing")
struct OCROnDemandPasteRouteTests {

    private let grace: TimeInterval = 1.0

    @Test("热路径：识别很快，直接粘进目标 App")
    func fastPathPastes() {
        #expect(OCRTaskCoordinator.onDemandPasteRoute(
            elapsed: 0.12, grace: grace, hasTarget: true, targetIsFrontmost: true
        ) == .paste)
    }

    /// 宽限期内不问前台是谁：`frontmostApplication` 的更新是异步的，刚 activate 完就问
    /// 容易读到旧值，把正常的快粘误判成「用户切走了」。
    @Test("热路径：前台状态还没更新也照样粘")
    func fastPathIgnoresFrontmost() {
        #expect(OCRTaskCoordinator.onDemandPasteRoute(
            elapsed: 0.12, grace: grace, hasTarget: true, targetIsFrontmost: false
        ) == .paste)
    }

    @Test("慢路径：目标仍在前台，照常粘")
    func slowPathStillFrontmostPastes() {
        #expect(OCRTaskCoordinator.onDemandPasteRoute(
            elapsed: 48, grace: grace, hasTarget: true, targetIsFrontmost: true
        ) == .paste)
    }

    @Test("慢路径：用户已切走，只写剪贴板")
    func slowPathSwitchedAwayCopiesOnly() {
        #expect(OCRTaskCoordinator.onDemandPasteRoute(
            elapsed: 48, grace: grace, hasTarget: true, targetIsFrontmost: false
        ) == .copyOnly)
    }

    @Test("宽限期边界按「达到即算慢」处理")
    func graceBoundaryIsSlow() {
        #expect(OCRTaskCoordinator.onDemandPasteRoute(
            elapsed: grace, grace: grace, hasTarget: true, targetIsFrontmost: false
        ) == .copyOnly)
    }

    /// 主窗口里触发（没有粘贴目标）走同一个判定，永远只复制。
    @Test("没有目标 App 时只复制")
    func noTargetCopiesOnly() {
        #expect(OCRTaskCoordinator.onDemandPasteRoute(
            elapsed: 0.1, grace: grace, hasTarget: false, targetIsFrontmost: false
        ) == .copyOnly)
    }
}
