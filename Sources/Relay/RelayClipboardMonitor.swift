import AppKit

private let RELAY_POLL_INTERVAL: Duration = .milliseconds(500)

@MainActor
final class RelayClipboardMonitor {

    private var pollTask: Task<Void, Never>?
    private var lastChangeCount: Int = 0
    private var lastContent: String = ""
    var onNewContent: (@MainActor (String) -> Void)?

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: RELAY_POLL_INTERVAL)
                self?.poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Call after writing to pasteboard to prevent self-detection.
    func skipNextChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        // Skip copies from PasteMemo itself (e.g. editing in main window)
        if let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           frontApp.contains("pastememo") { return }
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Skip consecutive duplicates (e.g. paste writes back the same content)
        guard text != lastContent else { return }
        lastContent = text
        onNewContent?(text)
    }
}
