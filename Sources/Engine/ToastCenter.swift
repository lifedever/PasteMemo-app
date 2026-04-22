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
    private var hostingView: NSHostingView<ToastHostContainer>?
    private let state = ToastCenterState()
    private var autoDismissTask: Task<Void, Never>?
    private var tearDownTask: Task<Void, Never>?
    /// Fires when PasteMemo itself has focus. Consumes ⌘Z so the source window
    /// doesn't also perform its own undo on top of ours.
    private var undoLocalMonitor: Any?
    /// Fires when another app has focus. Global monitors cannot consume events,
    /// so the target app still receives its native ⌘Z (this is desirable for
    /// paste-and-destroy: the target's paste undoes alongside our history
    /// restore).
    private var undoGlobalMonitor: Any?
    private var currentAction: (() -> Void)?
    /// Guards against posting the same undo toast twice in a row when an
    /// `ObservableObject` republishes the same `pending` state.
    private var currentID = UUID()

    /// Fixed canvas used by the panel. Large enough to fit any reasonable toast
    /// pill with room for drop shadow AND the slide-in transition, so SwiftUI
    /// can play the transition without the window frame clipping its edges.
    private static let canvasSize = NSSize(width: 520, height: 160)

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
        tearDownTask?.cancel()
        currentAction = onAction
        currentID = UUID()
        let thisID = currentID

        ensurePanel()
        positionPanel()
        panel?.orderFrontRegardless()

        // Spring animation on the SwiftUI side — transition is declared in
        // ToastHostContainer with `.move(edge: .bottom).combined(with: .opacity)`.
        withAnimation(.spring(response: 0.48, dampingFraction: 0.7)) {
            state.current = descriptor
        }

        refreshUndoShortcut(descriptor: descriptor)

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
    func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        currentAction = nil
        tearDownUndoShortcut()
        guard state.current != nil else { return }

        withAnimation(.easeIn(duration: 0.26)) {
            state.current = nil
        }

        // Defer orderOut until after SwiftUI's removal animation. Tracked by a
        // Task so a subsequent show() can cancel it and avoid hiding the panel
        // we just put back on screen.
        tearDownTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.state.current == nil else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    // MARK: - Internals

    private func invokeAction() {
        let action = currentAction
        action?()
    }

    private func ensurePanel() {
        if panel != nil { return }

        let container = ToastHostContainer(state: state) { [weak self] in
            self?.invokeAction()
        }
        let host = NSHostingView(rootView: container)
        host.frame = NSRect(origin: .zero, size: Self.canvasSize)

        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.canvasSize),
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
        newPanel.contentView = host

        panel = newPanel
        hostingView = host
    }

    /// Position the panel so the toast pill sits at its resting location
    /// (horizontal center of the visible frame, ~72pt above the bottom). The
    /// canvas extends well below and around the pill to give the slide
    /// transition and drop shadow room to breathe.
    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        // Toast pill visually rests at screen.minY + 72. The canvas is anchored
        // so the toast's bottom edge ends up there — `ToastHostContainer`
        // reserves `bottomInset` pt of transparent space below the pill for the
        // slide transition + shadow.
        let restingBottom = frame.minY + 72
        let y = restingBottom - ToastHostContainer.bottomInset
        let x = frame.midX - Self.canvasSize.width / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - ⌘Z shortcut

    /// Install both local and global ⌘Z monitors while a toast with an "⌘Z"
    /// action hint is on screen. Local fires when PasteMemo has focus and
    /// consumes the event so the source window doesn't double-undo. Global
    /// fires when another app has focus and does *not* consume the event,
    /// which is exactly what we want for paste-and-destroy: the target app's
    /// native ⌘Z rolls back the paste while our callback restores the history
    /// entry.
    private func refreshUndoShortcut(descriptor: ToastDescriptor) {
        tearDownUndoShortcut()
        guard let shortcut = descriptor.action?.shortcut, shortcut == "⌘Z" else {
            return
        }
        undoLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard Self.isCmdZ(event) else { return event }
            self.invokeAction()
            return nil
        }
        undoGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            guard Self.isCmdZ(event) else { return }
            self.invokeAction()
        }
    }

    private func tearDownUndoShortcut() {
        if let undoLocalMonitor { NSEvent.removeMonitor(undoLocalMonitor) }
        if let undoGlobalMonitor { NSEvent.removeMonitor(undoGlobalMonitor) }
        undoLocalMonitor = nil
        undoGlobalMonitor = nil
    }

    private static func isCmdZ(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "z"
    }
}

// MARK: - SwiftUI container

@MainActor
final class ToastCenterState: ObservableObject {
    @Published var current: ToastDescriptor?
}

/// SwiftUI root view for the toast panel. Owns the slide-in / fade-out
/// transitions so they ride on SwiftUI's animation engine (no brittle layer
/// transforms). `bottomInset` reserves transparent space below the pill for
/// the transition offset and drop shadow — the parent NSPanel is positioned
/// with the same inset so the pill still rests at the intended screen Y.
struct ToastHostContainer: View {
    /// Pt reserved below the pill for shadow + slide-in room. Keep in sync
    /// with ToastCenter.positionPanel(), which offsets the window by the same
    /// amount.
    static let bottomInset: CGFloat = 56

    @ObservedObject var state: ToastCenterState
    let onAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let descriptor = state.current {
                UnifiedToastView(descriptor: descriptor, onAction: onAction)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(descriptor.message)
            }
            Color.clear
                .frame(height: Self.bottomInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
