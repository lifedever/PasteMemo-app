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
    }

    /// Write file URLs to system pasteboard and simulate Cmd+V.
    static func pasteFile(_ pathsContent: String, monitor: RelayClipboardMonitor) async {
        let paths = pathsContent.components(separatedBy: "\n").filter { !$0.isEmpty }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
        pasteboard.writeObjects(urls)
        let pboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.setPropertyList(paths, forType: pboardType)
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
