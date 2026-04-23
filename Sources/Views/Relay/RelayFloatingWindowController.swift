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

        // Wrap content so width tracks @AppStorage("relayPanelWidth") set by the resize handle.
        let content = RelayPanelWidthWrapper(manager: relayManager)
        let hosting = NSHostingController(
            rootView: AnyView(content.ignoresSafeArea().modelContainer(PasteMemoApp.sharedModelContainer))
        )
        hosting.sizingOptions = .preferredContentSize
        hostingController = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 200),
            styleMask: [.nonactivatingPanel, .borderless],
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
        panel.acceptsMouseMovedEvents = true

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

        // Left-edge resize handle (borderless panels don't show resize cursor natively)
        let resizeHandle = ResizeHandleView(
            minWidth: MIN_WIDTH,
            maxWidth: MAX_WIDTH,
            pinTopRight: { [weak self] in
                guard let self, let win = self.window else { return }
                self.pinTopRight(win)
            },
            save: { width in
                UserDefaults.standard.set(Double(width), forKey: WIDTH_PREF_KEY)
            }
        )
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            resizeHandle.topAnchor.constraint(equalTo: container.topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            resizeHandle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 8),
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
            Task { @MainActor [weak self] in
                guard let self, let win = self.window else { return }
                let w = min(max(win.frame.size.width, MIN_WIDTH), MAX_WIDTH)
                UserDefaults.standard.set(Double(w), forKey: WIDTH_PREF_KEY)
                self.pinTopRight(win)
            }
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
        let delta = newHeight - panel.frame.height
        // Ignore sub-pixel noise (SwiftUI reports fractional sizes mid-animation).
        guard abs(delta) > 1 else { return }

        var frame = panel.frame
        frame.origin.y -= delta
        frame.size.height = newHeight

        // AppKit handles smooth frame interpolation natively with animate: true —
        // one animation source means SwiftUI content stays at its final layout
        // while NSWindow grows/shrinks around it. Hero (top-anchored) stays put.
        panel.setFrame(frame, display: true, animate: true)
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

/// Custom resize handle along the left edge for borderless panels.
/// Uses NSTrackingArea with .activeAlways so the cursor updates on
/// nonactivating panels (where the standard addCursorRect path is skipped).
private final class ResizeHandleView: NSView {
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private let pinTopRight: () -> Void
    private let save: (CGFloat) -> Void
    private var dragStartWidth: CGFloat = 0
    private var dragStartX: CGFloat = 0
    private var trackingArea: NSTrackingArea?
    private var isHovering = false { didSet { indicator.alphaValue = isHovering ? 1 : 0 } }

    private let indicator: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor
        v.layer?.cornerRadius = 1
        v.alphaValue = 0
        return v
    }()

    init(
        minWidth: CGFloat,
        maxWidth: CGFloat,
        pinTopRight: @escaping () -> Void,
        save: @escaping (CGFloat) -> Void
    ) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.pinTopRight = pinTopRight
        self.save = save
        super.init(frame: .zero)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 2),
            indicator.heightAnchor.constraint(equalToConstant: 28),
            indicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest receives point in SUPERVIEW coordinates. Claim hits inside our frame
        // so SwiftUI hostingView (which is a sibling below us) doesn't swallow the event.
        if frame.contains(point) { return self }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartWidth = window.frame.size.width
        dragStartX = NSEvent.mouseLocation.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let currentX = NSEvent.mouseLocation.x
        let delta = dragStartX - currentX  // pulling left = widening (right edge pinned)
        var newWidth = dragStartWidth + delta
        newWidth = min(max(newWidth, minWidth), maxWidth)

        var frame = window.frame
        let rightEdge = frame.maxX
        frame.size.width = newWidth
        frame.origin.x = rightEdge - newWidth
        window.setFrame(frame, display: true, animate: false)
        // Update AppStorage so SwiftUI content re-renders its .frame(width:) in sync
        save(newWidth)
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else { return }
        save(window.frame.size.width)
        pinTopRight()
    }
}

// MARK: - Width-tracking wrapper

private struct RelayPanelWidthWrapper: View {
    let manager: RelayManager
    @AppStorage("relayPanelWidth") private var panelWidth: Double = 320

    var body: some View {
        let w = min(max(panelWidth, 320), 800)
        RelayQueueView(manager: manager)
            .frame(width: w)
    }
}
