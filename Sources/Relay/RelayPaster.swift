import AppKit

private let PASTE_DELAY: Duration = .milliseconds(100)
private let V_KEY_CODE: UInt16 = 0x09

@MainActor
enum RelayPaster {

    /// Write text to system pasteboard and simulate Cmd+V.
    static func paste(_ text: String, monitor: RelayClipboardMonitor) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        monitor.skipNextChange()
        try? await Task.sleep(for: PASTE_DELAY)
        simulateCommandV()
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
}
