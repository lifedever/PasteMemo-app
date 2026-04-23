import SwiftUI
@preconcurrency import AppKit

/// Detects right-click via NSEvent local monitor. Does NOT interfere with
/// any SwiftUI gesture or hit-testing — completely transparent.
struct RightClickModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.background(
            RightClickDetector(action: action)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}

private struct RightClickDetector: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.alphaValue = 0
        context.coordinator.view = view
        context.coordinator.startMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitor()
    }

    final class Coordinator {
        var action: () -> Void
        weak var view: NSView?
        private var monitor: Any?

        init(action: @escaping () -> Void) { self.action = action }

        func startMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                let eventWindowNumber = event.windowNumber
                let locationInWindow = event.locationInWindow
                let view = self?.view
                let shouldTrigger = MainActor.assumeIsolated { () -> Bool in
                    guard let view,
                          let window = view.window,
                          window.windowNumber == eventWindowNumber else { return false }
                    let point = view.convert(locationInWindow, from: nil)
                    return view.bounds.contains(point)
                }
                if shouldTrigger {
                    self?.action()
                }
                return event // always pass through
            }
        }

        func stopMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stopMonitor() }
    }
}

extension View {
    func onRightClick(perform action: @escaping () -> Void) -> some View {
        modifier(RightClickModifier(action: action))
    }
}
