import AppKit
import SwiftUI

private let MIN_WIDTH: CGFloat = 320
private let MAX_WIDTH: CGFloat = 800
private let DEFAULT_WIDTH: CGFloat = 320
private let SCREEN_MARGIN: CGFloat = 16
private let MAX_HEIGHT: CGFloat = 500
private let WIDTH_PREF_KEY = "relayPanelWidth"

@MainActor
final class RelayFloatingWindowController {

    static let MAX_VISIBLE_ROWS = 12

    private var window: NSPanel?
    private var closeDelegate: WindowCloseDelegate?
    private var hostingController: NSHostingController<AnyView>?
    private let relayManager: RelayManager
    private var sizeObservation: NSKeyValueObservation?
    private var resizeObserver: Any?

    init(relayManager: RelayManager) {
        self.relayManager = relayManager
    }

    func show() {
        guard window == nil else { return }

        let storedWidth = UserDefaults.standard.double(forKey: WIDTH_PREF_KEY)
        let initialWidth = storedWidth > 0
            ? min(max(storedWidth, MIN_WIDTH), MAX_WIDTH)
            : DEFAULT_WIDTH

        let content = RelayQueueView(manager: relayManager)
        let hosting = NSHostingController(rootView: AnyView(content.ignoresSafeArea().frame(minWidth: MIN_WIDTH, maxWidth: MAX_WIDTH)))
        hosting.sizingOptions = .preferredContentSize
        hostingController = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 200),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.minSize = NSSize(width: MIN_WIDTH, height: 100)
        panel.maxSize = NSSize(width: MAX_WIDTH, height: CGFloat.greatestFiniteMagnitude)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: 200))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        let visualEffect = NSVisualEffectView(frame: container.bounds)
        visualEffect.material = .windowBackground
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]
        container.addSubview(visualEffect)

        let hostingView = hosting.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        panel.contentView = container

        let delegate = WindowCloseDelegate { [weak self] in
            self?.relayManager.deactivate()
        }
        panel.delegate = delegate
        closeDelegate = delegate

        // Observe preferredContentSize changes from SwiftUI
        sizeObservation = hosting.observe(\.preferredContentSize, options: [.new, .initial]) { [weak self] controller, _ in
            Task { @MainActor in
                self?.resizeToFit(controller.preferredContentSize)
            }
        }

        positionTopRight(panel, height: 200)
        panel.orderFrontRegardless()
        self.window = panel

        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, let win = self.window else { return }
            let w = min(max(win.frame.size.width, MIN_WIDTH), MAX_WIDTH)
            UserDefaults.standard.set(Double(w), forKey: WIDTH_PREF_KEY)
            self.pinTopRight(win)
        }
    }

    func dismiss() {
        sizeObservation?.invalidate()
        sizeObservation = nil
        if let obs = resizeObserver {
            NotificationCenter.default.removeObserver(obs)
            resizeObserver = nil
        }
        window?.close()
        window = nil
        closeDelegate = nil
        hostingController = nil
    }

    private func pinTopRight(_ panel: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = visible.maxX - frame.size.width - SCREEN_MARGIN
        frame.origin.y = visible.maxY - frame.size.height - SCREEN_MARGIN
        panel.setFrame(frame, display: true, animate: false)
    }

    func updateSize(for itemCount: Int) {
        // No-op: sizing is now driven by SwiftUI content via preferredContentSize
    }

    private func resizeToFit(_ contentSize: NSSize) {
        guard let panel = window else { return }
        let newHeight = min(contentSize.height, MAX_HEIGHT)
        guard abs(newHeight - panel.frame.height) > 1 else { return }

        var frame = panel.frame
        let heightDiff = newHeight - frame.height
        frame.origin.y -= heightDiff
        frame.size.height = newHeight
        panel.setFrame(frame, display: true, animate: false)
    }

    private func positionTopRight(_ panel: NSPanel, height: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.maxX - panel.frame.size.width - SCREEN_MARGIN
        let y = visibleFrame.maxY - height - SCREEN_MARGIN
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
