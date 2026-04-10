import AppKit
import SwiftUI

private let WINDOW_WIDTH: CGFloat = 320
private let SCREEN_MARGIN: CGFloat = 16
private let MAX_HEIGHT: CGFloat = 500

@MainActor
final class RelayFloatingWindowController {

    static let MAX_VISIBLE_ROWS = 12

    private var window: NSPanel?
    private var closeDelegate: WindowCloseDelegate?
    private var hostingController: NSHostingController<AnyView>?
    private let relayManager: RelayManager
    private var sizeObservation: NSKeyValueObservation?

    init(relayManager: RelayManager) {
        self.relayManager = relayManager
    }

    func show() {
        guard window == nil else { return }

        let content = RelayQueueView(manager: relayManager)
        let hosting = NSHostingController(rootView: AnyView(content.ignoresSafeArea().frame(width: WINDOW_WIDTH)))
        hosting.sizingOptions = .preferredContentSize
        hostingController = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: 200),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: 200))
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
    }

    func dismiss() {
        sizeObservation?.invalidate()
        sizeObservation = nil
        window?.close()
        window = nil
        closeDelegate = nil
        hostingController = nil
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
        let x = visibleFrame.maxX - WINDOW_WIDTH - SCREEN_MARGIN
        let y = visibleFrame.maxY - height - SCREEN_MARGIN
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
