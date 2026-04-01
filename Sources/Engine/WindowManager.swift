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
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: content())
        window.isReleasedWhenClosed = false
        window.center()
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
