import AppKit

private let PASTE_DELAY: Duration = .milliseconds(100)
private let V_KEY_CODE: UInt16 = 0x09

@MainActor
enum RelayPaster {

    /// Write text to system pasteboard and simulate Cmd+V.
    static func paste(_ text: String, monitor: RelayClipboardMonitor) async {
        let actions = RelayRuleResolver.currentRuleActions()
        let transformed = actions.isEmpty ? text : AutomationEngine.apply(actions, to: text)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transformed, forType: .string)
        monitor.skipNextChange()
        try? await Task.sleep(for: PASTE_DELAY)
        simulateCommandV()
        try? await Task.sleep(for: .milliseconds(100))
        simulatePostPasteKey()
    }

    /// Write image data to system pasteboard and simulate Cmd+V.
    static func pasteImage(_ data: Data, monitor: RelayClipboardMonitor) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let image = NSImage(data: data) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.setData(data, forType: .png)
            pasteboard.setData(data, forType: .tiff)
        }
        monitor.skipNextChange()
        try? await Task.sleep(for: PASTE_DELAY)
        simulateCommandV()
        try? await Task.sleep(for: .milliseconds(100))
        simulatePostPasteKey()
    }

    /// Write file URLs to system pasteboard and simulate Cmd+V. When `imageData` is provided
    /// (single image file case), also attach the decoded NSImage in the same writeObjects
    /// call so targets like Word embed the image rather than pasting a filename string.
    static func pasteFile(_ pathsContent: String, imageData: Data? = nil, monitor: RelayClipboardMonitor) async {
        let paths = pathsContent.components(separatedBy: "\n").filter { !$0.isEmpty }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // writeObjects clears the pasteboard on each call — combine URLs + image into one
        // invocation to avoid losing either. Mirrors the pattern in
        // ClipboardManager.writeToPasteboard's .image branch.
        var writables: [NSPasteboardWriting] = paths.map { URL(fileURLWithPath: $0) as NSURL }
        if let imageData, let image = NSImage(data: imageData) {
            writables.append(image)
        }
        if !writables.isEmpty {
            pasteboard.writeObjects(writables)
        }

        let pboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.setPropertyList(paths, forType: pboardType)

        monitor.skipNextChange()
        try? await Task.sleep(for: PASTE_DELAY)
        simulateCommandV()
        try? await Task.sleep(for: .milliseconds(100))
        simulatePostPasteKey()
    }

    /// Replay a captured pasteboard snapshot verbatim, then simulate ⌘V.
    /// Used for rich-text clips (备忘录/Word/Excel/网页图文) to achieve native-fidelity paste.
    static func pasteSnapshot(_ snapshot: Data, monitor: RelayClipboardMonitor) async {
        let pasteboard = NSPasteboard.general
        _ = ClipboardManager.shared.restorePasteboardSnapshot(snapshot, to: pasteboard)
        monitor.skipNextChange()
        try? await Task.sleep(for: PASTE_DELAY)
        simulateCommandV()
        try? await Task.sleep(for: .milliseconds(100))
        simulatePostPasteKey()
    }

    private static func simulateCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: V_KEY_CODE, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: V_KEY_CODE, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func simulatePostPasteKey() {
        guard let keyCode = RelayPostPasteKey.current.keyCode else { return }
        // Use privateState source so the event doesn't inherit currently-held
        // physical modifiers (e.g. user holding Ctrl during Ctrl+V relay paste).
        let source = CGEventSource(stateID: .privateState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        // Explicitly clear any modifier flags so arrow keys don't become Ctrl+Arrow etc.
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
