import AppKit
import SwiftUI

/// App-wide toast surface. Replaces the earlier mix of `GlobalToast` (standalone
/// black pill) and per-view `showCopiedToast` overlays with a single floating
/// NSPanel that every feature can post to. The panel lives above target apps so
/// undo-style toasts remain reachable after the Quick Panel dismisses.
///
/// Not a SwiftUI ObservableObject: the panel is a process-wide singleton and we
/// don't want every caller to bind to it. Callers post via `show(_:onAction:)`
/// and optionally `dismiss()`.
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<UnifiedToastView>?
    private var autoDismissTask: Task<Void, Never>?
    private var undoKeyMonitor: Any?
    private var currentDescriptor: ToastDescriptor?
    private var currentAction: (() -> Void)?
    /// Guards against posting the same undo toast twice in a row when an
    /// `ObservableObject` republishes the same `pending` state.
    private var currentID = UUID()

    private init() {}

    /// Display a toast, replacing whatever is already on-screen. For auto-dismiss
    /// toasts (`descriptor.duration != nil`) the panel hides itself after the
    /// duration elapses; for sticky toasts (undo-style) the caller is
    /// responsible for calling `dismiss()` when appropriate.
    ///
    /// - Parameter onAction: invoked when the user taps the action button or
    ///   (for undo-style toasts) presses ⌘Z while PasteMemo has focus.
    func show(_ descriptor: ToastDescriptor, onAction: (() -> Void)? = nil) {
        autoDismissTask?.cancel()
        currentDescriptor = descriptor
        currentAction = onAction
        currentID = UUID()
        let thisID = currentID

        let view = UnifiedToastView(descriptor: descriptor, onAction: { [weak self] in
            self?.invokeAction()
        })

        if let existing = panel, let hosting = hostingView {
            hosting.rootView = view
            hosting.layout()
            let size = hosting.fittingSize
            existing.setContentSize(size)
            reposition(panel: existing, contentSize: size)
            existing.orderFrontRegardless()
        } else {
            buildPanel(with: view)
        }

        refreshUndoShortcut()

        if let duration = descriptor.duration {
            autoDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.currentID == thisID else { return }
                    self.dismiss()
                }
            }
        }
    }

    /// Hide the current toast, if any. No-op when nothing is showing.
    ///
    /// The stored references (`panel`, `hostingView`) are cleared synchronously
    /// so a subsequent `show(_:)` on the same tick always builds a fresh panel
    /// instead of hijacking the one that's fading out. The old panel's fade-out
    /// completes in its own animation group and only tears itself down.
    func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        currentDescriptor = nil
        currentAction = nil
        tearDownUndoShortcut()
        guard let dismissing = panel else { return }
        panel = nil
        hostingView = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            dismissing.animator().alphaValue = 0
        }, completionHandler: {
            dismissing.orderOut(nil)
        })
    }

    // MARK: - Internals

    private func invokeAction() {
        let action = currentAction
        action?()
    }

    /// Distance the panel slides during the enter animation. Small enough to
    /// read as a gentle nudge upward rather than a full tray slide — matches
    /// the `.move(edge:.bottom)` feel of the original SwiftUI overlay.
    private static let slideOffset: CGFloat = 14

    private func buildPanel(with view: UnifiedToastView) {
        let hosting = NSHostingView(rootView: view)
        hosting.layout()
        let size = hosting.fittingSize

        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        newPanel.isExcludedFromWindowsMenu = true
        newPanel.hidesOnDeactivate = false
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.contentView = hosting

        // Start a bit below the resting position and fade in while sliding up,
        // so the toast has the same "move(edge:.bottom) + opacity" entrance
        // the original embedded version had.
        let restingOrigin = restingOrigin(for: newPanel, contentSize: size)
        newPanel.setFrameOrigin(NSPoint(x: restingOrigin.x, y: restingOrigin.y - Self.slideOffset))
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
            newPanel.animator().setFrameOrigin(restingOrigin)
        }

        panel = newPanel
        hostingView = hosting
    }

    /// Bottom-center of the active screen, well above the dock so the toast
    /// doesn't get crowded by menus, notifications, or the Control Centre pill.
    private func restingOrigin(for panel: NSPanel, contentSize: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let frame = screen.visibleFrame
        let x = frame.midX - contentSize.width / 2
        let y = frame.minY + 72
        return NSPoint(x: x, y: y)
    }

    private func reposition(panel: NSPanel, contentSize: NSSize) {
        panel.setFrameOrigin(restingOrigin(for: panel, contentSize: contentSize))
    }

    // MARK: - ⌘Z shortcut

    /// Install a local key monitor for ⌘Z when the current toast carries an
    /// action labelled with a shortcut. Only fires when PasteMemo itself has
    /// focus — if the user has switched to another app, the Undo button on the
    /// toast is the fallback path.
    private func refreshUndoShortcut() {
        tearDownUndoShortcut()
        guard let descriptor = currentDescriptor,
              let shortcut = descriptor.action?.shortcut,
              shortcut == "⌘Z"
        else { return }
        undoKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let isCmdZ = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                && event.charactersIgnoringModifiers?.lowercased() == "z"
            guard isCmdZ else { return event }
            self.invokeAction()
            return nil
        }
    }

    private func tearDownUndoShortcut() {
        if let undoKeyMonitor {
            NSEvent.removeMonitor(undoKeyMonitor)
        }
        undoKeyMonitor = nil
    }
}
