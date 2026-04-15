import ApplicationServices
import Combine
import Foundation

@MainActor
final class AccessibilityMonitor: ObservableObject {
    static let shared = AccessibilityMonitor()

    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    private var timer: Timer?

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
}
