import AppKit

@MainActor
enum GlobalToast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String, duration: TimeInterval = 1.2) {
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel = nil

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let hPad: CGFloat = 16
        let vPad: CGFloat = 10
        let width = label.frame.width + hPad * 2
        let height = label.frame.height + vPad * 2

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        container.layer?.cornerRadius = height / 2

        label.frame.origin = NSPoint(x: hPad, y: vPad)
        container.addSubview(label)

        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: container.frame.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newPanel.isExcludedFromWindowsMenu = true
        newPanel.hidesOnDeactivate = false
        newPanel.ignoresMouseEvents = true
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.contentView = container
        newPanel.alphaValue = 0

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - width / 2
            let y = screenFrame.minY + screenFrame.height * 0.25
            newPanel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        newPanel.orderFrontRegardless()
        self.panel = newPanel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            newPanel.animator().alphaValue = 1
        }

        hideTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                newPanel.animator().alphaValue = 0
            }, completionHandler: {
                newPanel.orderOut(nil)
                if self.panel === newPanel { self.panel = nil }
            })
        }
    }
}
