import AppKit
import SwiftUI

/// Can take the keyboard but never becomes main: the main window's key monitor works on
/// main-capable windows only, and would otherwise take ↑↓ / space / ⌫ from this one.
private final class SplitPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The split page in a window of its own, for the places that have no panel to take
/// over: the main window and the Relay queue. Same content, keys and look as the quick
/// panel's split page — only the frame around it differs.
@MainActor
final class SplitWindowController {

    static let shared = SplitWindowController()

    private static let SIZE = NSSize(width: 640, height: 520)

    private var panel: NSPanel?
    private var session: SplitSession?
    private var keyMonitor: Any?
    private var onConfirm: (([String]) -> Void)?
    private var onRelay: (([String]) -> Void)?

    private init() {}

    /// `onConfirm` gets the ticked pieces (⌘↵); `onRelay`, when given, offers ⌘R.
    func show(
        source: ClipSplit.Source,
        onConfirm: @escaping ([String]) -> Void,
        onRelay: (([String]) -> Void)? = nil
    ) {
        dismiss()
        let session = SplitSession(source: source)
        self.session = session
        self.onConfirm = onConfirm
        self.onRelay = onRelay

        let root = SplitWindowRoot(
            session: session,
            canRelay: onRelay != nil,
            onConfirm: { [weak self] in self?.confirm() },
            onRelay: { [weak self] in self?.relay() },
            onCancel: { [weak self] in self?.dismiss() }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        // Same three layers as the quick panel: blur behind, a tint that follows the
        // appearance, a 1px hairline on top.
        let frame = NSRect(origin: .zero, size: Self.SIZE)
        let container = PanelHostView(frame: frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = PANEL_CORNER_RADIUS
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)
        let tint = PanelTintView(frame: frame)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        container.addSubview(tint)
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let panel = SplitPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Above the Relay window and an always-on-top main window (both `.floating`).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = container
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel,
                  let session = self.session else { return event }
            switch SplitPageKeys.handle(event, session: session) {
            case .passThrough:
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if event.keyCode == 13, flags == .command { // ⌘W
                    self.dismiss()
                    return nil
                }
                return event
            case .handled:
                return nil
            case .confirm:
                self.confirm()
                return nil
            case .relay:
                self.relay()
                return nil
            case .cancel:
                self.dismiss()
                return nil
            }
        }
    }

    func dismiss() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        session = nil
        onConfirm = nil
        onRelay = nil
    }

    private func confirm() {
        guard let session, session.canConfirm, let handler = onConfirm else {
            NSSound.beep()
            return
        }
        let pieces = session.chosenPieces
        dismiss()
        handler(pieces)
    }

    private func relay() {
        guard let session, session.canConfirm, let handler = onRelay else {
            NSSound.beep()
            return
        }
        let pieces = session.chosenPieces
        dismiss()
        handler(pieces)
    }
}

private struct SplitWindowRoot: View {
    @ObservedObject var session: SplitSession
    let canRelay: Bool
    let onConfirm: () -> Void
    let onRelay: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "scissors", title: L10n.tr("action.split"))
            SplitPageView(session: session)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            HStack {
                Spacer()
                HStack(spacing: 10) {
                    SplitFooterKeys(
                        session: session,
                        showsRelay: canRelay,
                        onConfirm: onConfirm,
                        onRelay: onRelay,
                        onCancel: onCancel
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .modifier(GlassSurface(shape: Capsule()))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 640, height: 520)
    }
}
