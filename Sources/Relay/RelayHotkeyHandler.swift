import AppKit
import Carbon

private let RELAY_HOTKEY_SIGNATURE: OSType = 0x524C4159 // "RLAY"
private let DEFAULT_RELAY_KEY_CODE = 0x09 // V
private let RIGHT_ARROW_KEY_CODE = 0x7C
private let LEFT_ARROW_KEY_CODE = 0x7B

@MainActor
final class RelayHotkeyHandler {

    nonisolated(unsafe) static var current: RelayHotkeyHandler?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    var onPaste: (() -> Void)?
    var onSkip: (() -> Void)?
    var onPrevious: (() -> Void)?

    var pasteKeyCode: Int {
        guard UserDefaults.standard.object(forKey: "relayPasteKeyCode") != nil else { return DEFAULT_RELAY_KEY_CODE }
        return UserDefaults.standard.integer(forKey: "relayPasteKeyCode")
    }

    var pasteModifiers: Int {
        guard UserDefaults.standard.object(forKey: "relayPasteModifiers") != nil else { return controlKey }
        return UserDefaults.standard.integer(forKey: "relayPasteModifiers")
    }

    func start() {
        installEventHandler()
        // ID 1: Paste (Ctrl+V)
        registerHotKey(id: 1, keyCode: pasteKeyCode, modifiers: pasteModifiers)
        // ID 2: Skip (Ctrl+Right)
        registerHotKey(id: 2, keyCode: RIGHT_ARROW_KEY_CODE, modifiers: controlKey)
        // ID 3: Previous (Ctrl+Left)
        registerHotKey(id: 3, keyCode: LEFT_ARROW_KEY_CODE, modifiers: controlKey)
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
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
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
                Task { @MainActor in
                    switch hotKeyID.id {
                    case 1: RelayHotkeyHandler.current?.onPaste?()
                    case 2: RelayHotkeyHandler.current?.onSkip?()
                    case 3: RelayHotkeyHandler.current?.onPrevious?()
                    default: break
                    }
                }
                return noErr
            },
            1,
            &eventType,
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
