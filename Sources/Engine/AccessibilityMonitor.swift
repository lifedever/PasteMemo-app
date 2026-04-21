import AppKit
import ApplicationServices
import Combine
import Foundation
import PermissionFlow

@MainActor
final class AccessibilityMonitor: ObservableObject {
    static let shared = AccessibilityMonitor()

    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    private var timer: Timer?
    private let permissionController = PermissionFlow.makeController(
        configuration: .init(
            requiredAppURLs: [Bundle.main.bundleURL],
            promptForAccessibilityTrust: false
        )
    )

    private init() {
        startPolling()
    }

    private func startPolling() {
        // Poll every 2 seconds. Lightweight API call; cheaper than wiring
        // into the private AXAPI notification channel.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let current = AXIsProcessTrusted()
                if current != self.isTrusted {
                    self.isTrusted = current
                }
            }
        }
    }

    func openAccessibilitySettings(sourceFrameInScreen: CGRect? = nil) {
        let frame = sourceFrameInScreen ?? defaultSourceFrame()
        permissionController.authorize(
            pane: .accessibility,
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: frame,
            panelHint: L10n.tr("accessibility.panelHint"),
            panelTitle: L10n.tr("accessibility.panelTitle")
        )
    }

    private func defaultSourceFrame() -> CGRect {
        let location = NSEvent.mouseLocation
        return CGRect(x: location.x - 16, y: location.y - 16, width: 32, height: 32)
    }
}
