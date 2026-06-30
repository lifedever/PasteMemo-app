import AppKit
import SwiftUI

@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]
    private init() {}

    func show<Content: View>(
        id: String,
        title: String = "",
        size: NSSize,
        floating: Bool = true,
        styleMask: NSWindow.StyleMask = [.titled, .closable],
        frameAutosaveName: String? = nil,
        bridgeToolbar: Bool = false,
        autoResizesToContent: Bool = false,
        content: @escaping () -> Content,
        onClose: (() -> Void)? = nil
    ) {
        if let existing = windows[id], existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = CallbackWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(id)
        if bridgeToolbar || autoResizesToContent {
            let rootView: AnyView
            if autoResizesToContent {
                // 不用 host.sizingOptions = [.preferredContentSize]:那个选项会让 AppKit 在窗口
                // 的约束更新趟里同步回调 NSHostingController.preferredContentSize,而 SwiftUI 算
                // 这个尺寸时又反手 setNeedsUpdateConstraints 把窗口标脏 —— 在「正在更新约束」时
                // 再发起更新,macOS 26 (Tahoe) 的 AppKit 直接抛 NSException → SIGTRAP 崩溃
                // (issue #70;旧系统只是静默重排,所以表现为只在 Tahoe 必崩、且是时序竞态,
                // 换台机器/换个面板高度就未必复现)。
                // 改成单向数据流:SwiftUI 自己量内容理想高度 → onChange 上报 → 下一 runloop
                // (async,在 AppKit 布局趟之外)再 setFrame。约束更新趟里不再同步回调 SwiftUI,
                // 重入链被彻底切断;窗口高度随面板自适应的语义保留。
                let fixedWidth = size.width
                rootView = AnyView(
                    content().modifier(WindowContentHeightSizer { [weak window] height in
                        guard let window, height > 1 else { return }
                        DispatchQueue.main.async {
                            let current = window.contentRect(forFrameRect: window.frame).height
                            guard abs(current - height) > 0.5 else { return }
                            // 顶边(标题栏)固定,内容向下增减 —— 对齐 macOS 内容自适应窗口的习惯。
                            let oldFrame = window.frame
                            let frameSize = window.frameRect(
                                forContentRect: NSRect(x: 0, y: 0, width: fixedWidth, height: height)
                            ).size
                            let origin = NSPoint(x: oldFrame.origin.x, y: oldFrame.maxY - frameSize.height)
                            window.setFrame(NSRect(origin: origin, size: frameSize), display: true, animate: false)
                        }
                    })
                )
            } else {
                rootView = AnyView(content())
            }
            let host = NSHostingController(rootView: rootView)
            if bridgeToolbar {
                // SwiftUI `.toolbar` 内容要桥接成 NSToolbar 才会显示在标题栏
                // (主管理器窗口用,macOS 14+)。
                host.sceneBridgingOptions = [.toolbars]
                window.toolbarStyle = .unified
                // SwiftUI WindowGroup 默认带 fullSizeContentView,NavigationSplitView
                // 的侧边栏靠它延伸到标题栏下实现通顶;手建 NSWindow 不补这个样式位,
                // 侧边栏会从标题栏下方才开始,顶部断一截。
                window.styleMask.insert(.fullSizeContentView)
            }
            window.contentViewController = host
            // 必须先给初始尺寸再 center():autoResizesToContent 时 SwiftUI 首次布局
            // 是异步的,若以接近零的尺寸居中,后续内容尺寸到位时窗口会整个偏出去。
            window.setContentSize(size)
        } else {
            window.contentView = NSHostingView(rootView: content())
        }
        window.isReleasedWhenClosed = false
        if styleMask.contains(.resizable) {
            window.contentMinSize = NSSize(width: size.width, height: min(size.height, 470))
        }
        if let frameAutosaveName {
            window.setFrameAutosaveName(frameAutosaveName)
            if !window.setFrameUsingName(frameAutosaveName) { window.center() }
        } else {
            window.center()
        }
        window.level = floating ? .floating : .normal

        window.onCloseCallback = { [weak self] in
            self?.windows.removeValue(forKey: id)
            onClose?()
        }

        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(id: String) {
        windows[id]?.close()
        windows.removeValue(forKey: id)
    }
}

/// 量出被包裹内容的理想高度,通过回调上报(单向数据流)。配合 WindowManager 的
/// autoResizesToContent 分支用,替代 NSHostingController.sizingOptions =
/// [.preferredContentSize](后者在 macOS 26 会触发约束更新重入崩溃,见 issue #70)。
private struct WindowContentHeightSizer: ViewModifier {
    let onHeight: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.height, initial: true) { _, newHeight in
                        onHeight(newHeight)
                    }
            }
        )
    }
}

private class CallbackWindow: NSWindow, NSWindowDelegate {
    var onCloseCallback: (() -> Void)?

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        onCloseCallback?()
    }
}
