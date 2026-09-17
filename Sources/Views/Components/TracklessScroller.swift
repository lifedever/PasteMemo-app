import AppKit
import SwiftUI

/// 只画滑块、不画槽轨的滚动条。
///
/// overlay 滚动条平时只是一根半透明细条，但鼠标一靠近就会变宽并把那条灰色凹槽底
/// 画出来——贴在快捷面板的玻璃边上很脏。这里只拦掉槽轨的绘制，滑块照常。
///
/// **不改 `scrollerStyle`**：那是「系统设置 → 外观 → 显示滚动条」的用户选择，有人
/// 出于视力需要专门设成「始终」（常驻、占布局宽度）。去掉装饰可以，替用户改设置不行。
final class KnobOnlyScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

enum TracklessScroller {
    /// 幂等：已经装过就不再换，避免 updateNSView 每次都新建一个 scroller。
    @MainActor
    static func install(on scrollView: NSScrollView) {
        if scrollView.hasVerticalScroller, !(scrollView.verticalScroller is KnobOnlyScroller) {
            scrollView.verticalScroller = KnobOnlyScroller()
        }
        if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is KnobOnlyScroller) {
            scrollView.horizontalScroller = KnobOnlyScroller()
        }
    }
}

/// 挂到 SwiftUI `ScrollView` 上：往上找到外包的 `NSScrollView` 再换 scroller。
///
/// SwiftUI 不暴露底层 scroll view，只能这么摸。摸不到的后果只是轨道还在，不影响功能，
/// 所以失败不报错——将来 SwiftUI 换了内部结构也不会炸。
struct TracklessScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        InstallerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? InstallerView)?.installSoon()
    }

    private final class InstallerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installSoon()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            installSoon()
        }

        /// 延到下一轮 runloop：viewDidMoveTo* 触发时 SwiftUI 的滚动容器可能还没接上，
        /// 这时候往上找是找不到 NSScrollView 的。
        func installSoon() {
            DispatchQueue.main.async { [weak self] in
                self?.install()
            }
        }

        private func install() {
            var current: NSView? = self
            while let view = current {
                if let scrollView = view as? NSScrollView {
                    TracklessScroller.install(on: scrollView)
                    return
                }
                current = view.superview
            }
        }
    }
}

extension View {
    func hideScrollerTrack() -> some View {
        background(TracklessScrollerInstaller())
    }
}
