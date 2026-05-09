import AppKit

extension NSPasteboard.PasteboardType {
    /// Self-write marker. Attached to any pasteboard write PasteMemo initiates so the
    /// polling capture path can tell "this change came from us" from "user copied
    /// something externally" without depending solely on `changeCount` timing. The
    /// `changeCount`-based skip (`lastChangeCount` / `skipNextChange`) stays as the
    /// fast path; this marker is the defensive fallback for the race where another
    /// clipboard manager writes between our setData and our baseline update.
    static let fromPasteMemo = NSPasteboard.PasteboardType(rawValue: "com.lifedever.pastememo")

    /// AI Agent source marker. Attached when a `clipboard_set` MCP tool call writes the
    /// pasteboard — value is the MCP client's `clientInfo.name` (e.g. "claude-code", "cursor").
    /// `ClipboardManager.captureAndSave` reads this and stores it onto `ClipItem.agentSource`,
    /// so the side panel / quick panel can offer the "AI Agent" filter category.
    static let agentSource = NSPasteboard.PasteboardType(rawValue: "com.lifedever.pastememo.agent-source")
}

extension NSPasteboard {
    /// Attach the self-write marker to the pasteboard. Call after writing actual
    /// content but before updating `lastChangeCount` / `skipNextChange`, so the marker
    /// lives on the same change cycle. `setString` adds the type without bumping
    /// `changeCount`, so it doesn't disturb the baseline the caller is about to capture.
    func markAsPasteMemoWrite() {
        setString("", forType: .fromPasteMemo)
    }

    /// True when the current pasteboard carries the self-write marker on any item.
    /// Used by pollers to skip capturing our own writes even if the `changeCount`
    /// baseline was knocked out of sync by a third-party clipboard manager.
    var isPasteMemoWrite: Bool {
        pasteboardItems?.contains(where: { $0.types.contains(.fromPasteMemo) }) ?? false
    }
}
