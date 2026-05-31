import AppKit

private let PASTE_DELAY: Duration = .milliseconds(100)
private let POST_PASTE_DELAY: Duration = .milliseconds(100)
// 一键全部粘贴（burst 模式）：连续粘到同一个目标 App，不需要给系统切窗/AX 留太多余量。
// 实测从 100/100ms 降到 20/20ms 单条耗时缩到 ~60ms（含事件本身），100 条从 ~38s 降到 ~6s。
private let BURST_PASTE_DELAY: Duration = .milliseconds(20)
private let BURST_POST_PASTE_DELAY: Duration = .milliseconds(20)

@MainActor
enum RelayPaster {

    /// Write text to system pasteboard and simulate Cmd+V. Callers decide whether to
    /// pass `actions` by checking the active relay rule's conditions first; if the
    /// conditions don't match, pass an empty array to paste the content verbatim.
    static func paste(_ text: String, actions: [RuleAction] = [], monitor: RelayClipboardMonitor, burst: Bool = false) async {
        let transformed = actions.isEmpty ? text : AutomationEngine.apply(actions, to: text)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transformed, forType: .string)
        pasteboard.markAsPasteMemoWrite()
        monitor.skipNextChange()
        try? await Task.sleep(for: burst ? BURST_PASTE_DELAY : PASTE_DELAY)
        simulateCommandV()
        try? await Task.sleep(for: burst ? BURST_POST_PASTE_DELAY : POST_PASTE_DELAY)
        simulatePostPasteKey()
    }

    /// Write image data to system pasteboard and simulate Cmd+V.
    static func pasteImage(_ data: Data, monitor: RelayClipboardMonitor, burst: Bool = false) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let image = NSImage(data: data) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.setData(data, forType: .png)
            pasteboard.setData(data, forType: .tiff)
        }
        pasteboard.markAsPasteMemoWrite()
        monitor.skipNextChange()
        try? await Task.sleep(for: burst ? BURST_PASTE_DELAY : PASTE_DELAY)
        simulateCommandV()
        try? await Task.sleep(for: burst ? BURST_POST_PASTE_DELAY : POST_PASTE_DELAY)
        simulatePostPasteKey()
    }

    /// Write file URLs to system pasteboard and simulate Cmd+V. When `imageData` is provided
    /// (single image file case), also attach the decoded NSImage in the same writeObjects
    /// call so targets like Word embed the image rather than pasting a filename string.
    static func pasteFile(_ pathsContent: String, imageData: Data? = nil, monitor: RelayClipboardMonitor, burst: Bool = false) async {
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

        pasteboard.markAsPasteMemoWrite()
        monitor.skipNextChange()
        try? await Task.sleep(for: burst ? BURST_PASTE_DELAY : PASTE_DELAY)
        simulateCommandV()
        try? await Task.sleep(for: burst ? BURST_POST_PASTE_DELAY : POST_PASTE_DELAY)
        simulatePostPasteKey()
    }

    /// Replay a captured pasteboard snapshot verbatim, then simulate ⌘V.
    /// Used for rich-text clips (备忘录/Word/Excel/网页图文) to achieve native-fidelity paste.
    /// `restorePasteboardSnapshot` internally drops Office-private UTIs so Word paste
    /// doesn't get hijacked by its private internal clipboard (issue #28).
    static func pasteSnapshot(_ snapshot: Data, monitor: RelayClipboardMonitor, burst: Bool = false) async {
        let pasteboard = NSPasteboard.general
        _ = ClipboardManager.shared.restorePasteboardSnapshot(snapshot, to: pasteboard)
        pasteboard.markAsPasteMemoWrite()
        monitor.skipNextChange()
        try? await Task.sleep(for: burst ? BURST_PASTE_DELAY : PASTE_DELAY)
        simulateCommandV()
        try? await Task.sleep(for: burst ? BURST_POST_PASTE_DELAY : POST_PASTE_DELAY)
        simulatePostPasteKey()
    }

    private static func simulateCommandV() {
        // privateState：合成事件的修饰位完全由我们指定，不会并入用户此刻按住的物理键
        // （典型：Ctrl 触发接力粘贴时 Ctrl 还压着）。否则合成的 ⌘V 会带上 Ctrl 位，
        // 目标 App 看到 Ctrl+⌘V —— Word 里是「选择性粘贴」、多数编辑器无绑定（静默失败）。
        let source = CGEventSource(stateID: .privateState)
        // V 按当前键盘布局取键码（Dvorak / Colemak / AZERTY 也得到 ⌘V）。
        let vKeyCode = KeyboardLayout.virtualKeyForV()
        // ⌘ 是修饰键，键码与布局无关（kVK_Command = 0x37）。
        let cmdKeyCode: CGKeyCode = 0x37
        // 发「真实的 ⌘ 按下 → V 按下 → V 抬起 → ⌘ 抬起」四连事件，而不是只在 V 上挂 flag。
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKeyCode, keyDown: false) else { return }
        // flags 带「抽象 command 位」+「设备相关左⌘位 0x8」。远程桌面 / 流式客户端（MS Remote
        // Desktop、UU远程，issue #60）读 device-dependent 位翻译具体物理键，只设抽象位时它们认为
        // 没按 ⌘、只收到裸 v。与 ClipboardManager.simulateCommandV 同一修复，详见 DEVICE_LCMD_FLAG。
        let cmdFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | DEVICE_LCMD_FLAG)
        cmdDown.flags = cmdFlags
        vDown.flags = cmdFlags
        vUp.flags = cmdFlags
        cmdUp.flags = []   // ⌘ 已抬起
        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
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
        // 走 HID 层与 simulateCommandV 一致，确保接力后的补发键也能进远程桌面（issue #60）。
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
