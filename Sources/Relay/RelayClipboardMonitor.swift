import AppKit

private let RELAY_POLL_INTERVAL: Duration = .milliseconds(500)

@MainActor
final class RelayClipboardMonitor {

    private var pollTask: Task<Void, Never>?
    private var lastChangeCount: Int = 0
    private var lastContentKey: String = ""
    var onNewClip: (@MainActor (ClipItem) -> Void)?

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

    /// Reset the consecutive-duplicate fingerprint so a clip that just got cleared from
    /// the queue can be re-enqueued by re-copying the same content. Without this, the
    /// fingerprint persists across `clearAll` and silently drops the next identical copy.
    func resetDedup() {
        lastContentKey = ""
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        // Defensive fallback for races where `lastChangeCount` was knocked out of sync
        // by a third-party clipboard manager writing between our paste and our baseline
        // update — the self-write marker still identifies this cycle as ours.
        if pasteboard.isPasteMemoWrite { return }
        // Skip copies from PasteMemo itself (e.g. editing in main window)
        let frontApp = NSWorkspace.shared.frontmostApplication
        if let bundleID = frontApp?.bundleIdentifier, bundleID.contains("pastememo") { return }
        guard let clip = ClipboardManager.shared.captureCurrentClipboard(sourceApp: frontApp?.localizedName) else { return }
        // captureCurrentClipboard takes `sourceApp` (display name) but not `sourceAppBundleID`.
        // Without the bundle ID, rule conditions like "sourceApp = Word" can't match on the
        // relay-paste path (issue #22 follow-up: relay monitor is a separate capture path
        // from the main ClipboardManager flow that normally sets this field in-line).
        clip.sourceAppBundleID = frontApp?.bundleIdentifier
        // Opt-in dedup: skip if user hasn't allowed repeats and content matches previous.
        let allowRepeat = UserDefaults.standard.bool(forKey: "relayAllowRepeatCopy")
        let key = dedupKey(for: clip)
        if !allowRepeat, key == lastContentKey { return }
        lastContentKey = key
        onNewClip?(clip)
    }

    /// Identity fingerprint used for consecutive-duplicate detection. Uses text content
    /// for text-like clips and imageData byte count + prefix for images (avoids hashing
    /// megabytes on every poll).
    private func dedupKey(for clip: ClipItem) -> String {
        if clip.contentType == .image, let data = clip.imageData {
            return "image:\(data.count):\(data.prefix(32).hashValue)"
        }
        return "text:\(clip.content)"
    }
}
