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
            let host = NSHostingController(rootView: content())
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
            if autoResizesToContent {
                // 窗口尺寸跟随 SwiftUI 内容(设置窗口用:高度随当前面板变化,
                // 对齐原 Settings scene 的自适应语义)。
                host.sizingOptions = [.preferredContentSize]
            }
            window.contentViewController = host
            // 必须先给初始尺寸再 center():autoResizesToContent 时 SwiftUI 首次布局
            // 是异步的,若以接近零的尺寸居中,后续内容尺寸到位时 AppKit 以左上角为锚
            // 向右下展开,窗口会整个偏到屏幕右下象限。
            window.setContentSize(size)
        } else {
            window.contentView = NSHostingView(rootView: content())
        }
        window.isReleasedWhenClosed = false
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
