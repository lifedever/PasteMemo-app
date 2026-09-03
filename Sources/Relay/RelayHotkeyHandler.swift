import AppKit
import Carbon

private let RELAY_HOTKEY_SIGNATURE: OSType = 0x524C4159 // "RLAY"
private let DEFAULT_RELAY_KEY_CODE = 0x09 // V
private let RIGHT_ARROW_KEY_CODE = 0x7C
private let LEFT_ARROW_KEY_CODE = 0x7B

/// Carbon hotkey callback. File-scope `nonisolated` for the same reason as
/// `hotkeyEventHandler` in HotkeyManager.swift: a closure literal formed in
/// a @MainActor context gets a dynamic executor check injected into its
/// C-function thunk, which crashes on macOS 26/27 betas when Carbon
/// re-enters mid-drain (v1.7.13 crash report, 2026-08-12).
private nonisolated func relayHotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    // Only respond to our own hotkey signature; other handlers
    // (e.g. quick panel) use the same id space with different signatures.
    guard hotKeyID.signature == RELAY_HOTKEY_SIGNATURE else {
        return OSStatus(eventNotHandledErr)
    }
    let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
    // 粘贴类动作等热键「释放」时才执行，跳过 / 回退用「按下」保持即按即响应。
    // 原因（issue #87）：粘贴要合成 ⌘V，而接力热键默认 ⌃V 与之共用 V 键。按下时触发的话，
    // 合成 ⌘V 时物理 V 往往还压着，系统丢弃这个重复的 V keyDown，目标 App 收不到粘贴，
    // 但队列已经 advance——表现为「进度在走、内容没粘上」。补发合成 keyUp 无效：物理键
    // 真按着时 keyState 依然为 true（实测四次尝试全失败）。改在释放时执行，按键必然已抬起。
    // 快速点按时松手只差几十毫秒，比原先固定等 100ms 更快；按住不放则只粘一次，
    // 顺带修掉「按住会以自动重复的速度刷空整个队列」。
    let id = hotKeyID.id
    guard isRelease == (id == 1 || id == 4) else { return noErr }
    Task { @MainActor in
        switch id {
        case 1: RelayHotkeyHandler.current?.onPaste?()
        case 2: RelayHotkeyHandler.current?.onSkip?()
        case 3: RelayHotkeyHandler.current?.onPrevious?()
        case 4: RelayHotkeyHandler.current?.onPasteAll?()
        default: break
        }
    }
    return noErr
}

@MainActor
final class RelayHotkeyHandler {

    nonisolated(unsafe) static var current: RelayHotkeyHandler?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    var onPaste: (() -> Void)?
    var onSkip: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onPasteAll: (() -> Void)?

    var pasteKeyCode: Int {
        guard UserDefaults.standard.object(forKey: "relayPasteKeyCode") != nil else { return DEFAULT_RELAY_KEY_CODE }
        return UserDefaults.standard.integer(forKey: "relayPasteKeyCode")
    }

    var pasteModifiers: Int {
        guard UserDefaults.standard.object(forKey: "relayPasteModifiers") != nil else { return controlKey }
        return UserDefaults.standard.integer(forKey: "relayPasteModifiers")
    }

    /// Paste-all 默认 ⌥⌃V，复用 paste 的键码加 option 修饰键，跟单条粘贴语义对齐。
    var pasteAllKeyCode: Int {
        guard UserDefaults.standard.object(forKey: "relayPasteAllKeyCode") != nil else { return pasteKeyCode }
        return UserDefaults.standard.integer(forKey: "relayPasteAllKeyCode")
    }

    var pasteAllModifiers: Int {
        guard UserDefaults.standard.object(forKey: "relayPasteAllModifiers") != nil else { return optionKey | controlKey }
        return UserDefaults.standard.integer(forKey: "relayPasteAllModifiers")
    }

    func start() {
        installEventHandler()
        // ID 1: Paste (Ctrl+V)
        registerHotKey(id: 1, keyCode: pasteKeyCode, modifiers: pasteModifiers)
        // ID 2: Skip (Ctrl+Right)
        registerHotKey(id: 2, keyCode: RIGHT_ARROW_KEY_CODE, modifiers: controlKey)
        // ID 3: Previous (Ctrl+Left)
        registerHotKey(id: 3, keyCode: LEFT_ARROW_KEY_CODE, modifiers: controlKey)
        // ID 4: Paste All (Option+Ctrl+V)
        registerHotKey(id: 4, keyCode: pasteAllKeyCode, modifiers: pasteAllModifiers)
    }

    func stop() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    // MARK: - Carbon Hotkey

    private func installEventHandler() {
        // 同时订阅按下与释放：粘贴类热键走释放（见 relayHotkeyEventHandler 的说明），
        // 跳过 / 回退走按下。
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        InstallEventHandler(
            GetApplicationEventTarget(),
            relayHotkeyEventHandler,
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandler
        )
    }

    private func registerHotKey(id: UInt32, keyCode: Int, modifiers: Int) {
        let hotKeyID = EventHotKeyID(signature: RELAY_HOTKEY_SIGNATURE, id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if let ref { hotKeyRefs[id] = ref }
    }
}
