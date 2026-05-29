import AppKit
import Carbon

private let HOTKEY_SIGNATURE: OSType = 0x434D454D // "CMEM"
private let DEFAULT_KEY_CODE = 0x09 // V
private let DEFAULT_MODIFIERS = cmdKey | shiftKey
private let HOTKEY_ID_QUICK_PANEL: UInt32 = 1
private let HOTKEY_ID_MANAGER: UInt32 = 2
private let HOTKEY_ID_RELAY: UInt32 = 3
/// 置顶连续快粘：⌘1–9 的 hotkey ID 从此基址连续分配（10…18）
private let HOTKEY_ID_QUICK_PASTE_DIGIT_BASE: UInt32 = 10
private let MANAGER_HOTKEY_GLOBAL_ENABLED_KEY = "managerHotkeyGlobalEnabled"

/// ⌘1–9 的物理键码，与 QuickPanelView.digitKeyMap 一一对应（用 kVK_ANSI_* 而非裸数字）
private let QUICK_PASTE_DIGIT_KEYCODES: [Int] = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
]

@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published var isQuickPanelVisible = false
    private var hotKeyRef: EventHotKeyRef?
    private var managerHotKeyRef: EventHotKeyRef?
    private var relayHotKeyRef: EventHotKeyRef?
    /// 置顶期间临时注册的 ⌘1–9 全局热键；取消置顶/关闭面板时注销
    private var quickPasteDigitRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?

    // MARK: - Quick Panel Shortcut

    var isCleared: Bool {
        UserDefaults.standard.integer(forKey: "hotkeyKeyCode") == -1
    }

    var currentKeyCode: Int {
        let stored = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        if stored == -1 { return -1 }
        guard UserDefaults.standard.object(forKey: "hotkeyKeyCode") != nil else { return DEFAULT_KEY_CODE }
        return stored
    }

    var currentModifiers: Int {
        let stored = UserDefaults.standard.integer(forKey: "hotkeyModifiers")
        if stored == -1 { return 0 }
        guard UserDefaults.standard.object(forKey: "hotkeyModifiers") != nil else { return DEFAULT_MODIFIERS }
        return stored
    }

    var displayString: String {
        guard !isCleared else { return "" }
        return shortcutDisplayString(keyCode: currentKeyCode, modifiers: currentModifiers)
    }

    func clearShortcut() {
        UserDefaults.standard.set(-1, forKey: "hotkeyKeyCode")
        UserDefaults.standard.set(-1, forKey: "hotkeyModifiers")
        unregisterHotKey()
        objectWillChange.send()
    }

    // MARK: - Manager Shortcut

    var isManagerCleared: Bool {
        UserDefaults.standard.object(forKey: "managerHotkeyKeyCode") == nil
            || UserDefaults.standard.integer(forKey: "managerHotkeyKeyCode") == -1
    }

    var managerKeyCode: Int {
        let stored = UserDefaults.standard.integer(forKey: "managerHotkeyKeyCode")
        if stored == -1 { return -1 }
        guard UserDefaults.standard.object(forKey: "managerHotkeyKeyCode") != nil else { return -1 }
        return stored
    }

    var managerModifiers: Int {
        let stored = UserDefaults.standard.integer(forKey: "managerHotkeyModifiers")
        if stored == -1 { return 0 }
        guard UserDefaults.standard.object(forKey: "managerHotkeyModifiers") != nil else { return 0 }
        return stored
    }

    var isManagerHotkeyGlobalEnabled: Bool {
        guard UserDefaults.standard.object(forKey: MANAGER_HOTKEY_GLOBAL_ENABLED_KEY) != nil else { return true }
        return UserDefaults.standard.bool(forKey: MANAGER_HOTKEY_GLOBAL_ENABLED_KEY)
    }

    func updateManagerShortcut(keyCode: Int, modifiers: Int) {
        UserDefaults.standard.set(keyCode, forKey: "managerHotkeyKeyCode")
        UserDefaults.standard.set(modifiers, forKey: "managerHotkeyModifiers")
        unregisterManagerHotKey()
        registerManagerHotKey()
        objectWillChange.send()
    }

    func updateManagerHotkeyGlobalEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: MANAGER_HOTKEY_GLOBAL_ENABLED_KEY)
        unregisterManagerHotKey()
        registerManagerHotKey()
        objectWillChange.send()
    }

    func clearManagerShortcut() {
        UserDefaults.standard.set(-1, forKey: "managerHotkeyKeyCode")
        UserDefaults.standard.set(-1, forKey: "managerHotkeyModifiers")
        unregisterManagerHotKey()
        objectWillChange.send()
    }

    // MARK: - Relay Shortcut

    var isRelayCleared: Bool {
        UserDefaults.standard.object(forKey: "relayHotkeyKeyCode") == nil
            || UserDefaults.standard.integer(forKey: "relayHotkeyKeyCode") == -1
    }

    var relayKeyCode: Int {
        let stored = UserDefaults.standard.integer(forKey: "relayHotkeyKeyCode")
        if stored == -1 { return -1 }
        guard UserDefaults.standard.object(forKey: "relayHotkeyKeyCode") != nil else { return -1 }
        return stored
    }

    var relayModifiers: Int {
        let stored = UserDefaults.standard.integer(forKey: "relayHotkeyModifiers")
        if stored == -1 { return 0 }
        guard UserDefaults.standard.object(forKey: "relayHotkeyModifiers") != nil else { return 0 }
        return stored
    }

    func updateRelayShortcut(keyCode: Int, modifiers: Int) {
        UserDefaults.standard.set(keyCode, forKey: "relayHotkeyKeyCode")
        UserDefaults.standard.set(modifiers, forKey: "relayHotkeyModifiers")
        unregisterRelayHotKey()
        registerRelayHotKey()
        objectWillChange.send()
    }

    func clearRelayShortcut() {
        UserDefaults.standard.set(-1, forKey: "relayHotkeyKeyCode")
        UserDefaults.standard.set(-1, forKey: "relayHotkeyModifiers")
        unregisterRelayHotKey()
        objectWillChange.send()
    }

    // MARK: - Registration

    private init() {}

    func register() {
        // Already fully registered
        guard hotKeyRef == nil || eventHandler == nil else { return }
        // Clean up partial state
        unregisterHotKey()
        unregisterManagerHotKey()
        unregisterRelayHotKey()
        if let handler = eventHandler { RemoveEventHandler(handler); eventHandler = nil }

        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = UInt32(kEventHotKeyPressed)

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                Task { @MainActor in
                    switch hotKeyID.id {
                    case HOTKEY_ID_QUICK_PANEL:
                        HotkeyManager.shared.toggleQuickPanel()
                    case HOTKEY_ID_MANAGER:
                        AppAction.shared.openMainWindow?()
                    case HOTKEY_ID_RELAY:
                        RelayManager.shared.activate()
                    case HOTKEY_ID_QUICK_PASTE_DIGIT_BASE...(HOTKEY_ID_QUICK_PASTE_DIGIT_BASE + 8):
                        // 置顶连续快粘：把 1–9 交给 QuickPanelView 粘贴对应项（不关面板）
                        let index = Int(hotKeyID.id - HOTKEY_ID_QUICK_PASTE_DIGIT_BASE) + 1
                        NotificationCenter.default.post(
                            name: .quickPanelPasteDigit, object: nil, userInfo: ["index": index]
                        )
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )

        registerHotKey()
        registerManagerHotKey()
        registerRelayHotKey()
        startDoubleTapDetector()
    }

    func updateShortcut(keyCode: Int, modifiers: Int) {
        UserDefaults.standard.set(keyCode, forKey: "hotkeyKeyCode")
        UserDefaults.standard.set(modifiers, forKey: "hotkeyModifiers")
        unregister()
        register()
        objectWillChange.send()
    }

    func unregister() {
        unregisterHotKey()
        unregisterManagerHotKey()
        unregisterRelayHotKey()
        unregisterQuickPasteDigitHotkeys()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        DoubleTapDetector.shared.stop()
    }

    private func registerHotKey() {
        guard !isCleared else { return }
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = HOTKEY_SIGNATURE
        hotKeyID.id = HOTKEY_ID_QUICK_PANEL

        RegisterEventHotKey(
            UInt32(currentKeyCode),
            UInt32(currentModifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func registerManagerHotKey() {
        guard isManagerHotkeyGlobalEnabled, !isManagerCleared else { return }
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = HOTKEY_SIGNATURE
        hotKeyID.id = HOTKEY_ID_MANAGER

        RegisterEventHotKey(
            UInt32(managerKeyCode),
            UInt32(managerModifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &managerHotKeyRef
        )
    }

    private func unregisterManagerHotKey() {
        guard let ref = managerHotKeyRef else { return }
        UnregisterEventHotKey(ref)
        managerHotKeyRef = nil
    }

    private func registerRelayHotKey() {
        guard !isRelayCleared else { return }
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = HOTKEY_SIGNATURE
        hotKeyID.id = HOTKEY_ID_RELAY

        RegisterEventHotKey(
            UInt32(relayKeyCode),
            UInt32(relayModifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &relayHotKeyRef
        )
    }

    private func unregisterRelayHotKey() {
        guard let ref = relayHotKeyRef else { return }
        UnregisterEventHotKey(ref)
        relayHotKeyRef = nil
    }

    /// 面板置顶时调用：全局注册 ⌘1–9，使用户点进目标 App 后仍能连续快捷粘贴。
    /// 复用启动时已安装的 `eventHandler` 分发；幂等。
    func registerQuickPasteDigitHotkeys() {
        guard quickPasteDigitRefs.isEmpty, eventHandler != nil else { return }
        for (offset, keyCode) in QUICK_PASTE_DIGIT_KEYCODES.enumerated() {
            var hotKeyID = EventHotKeyID()
            hotKeyID.signature = HOTKEY_SIGNATURE
            hotKeyID.id = HOTKEY_ID_QUICK_PASTE_DIGIT_BASE + UInt32(offset)
            var ref: EventHotKeyRef?
            RegisterEventHotKey(
                UInt32(keyCode),
                UInt32(cmdKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            quickPasteDigitRefs.append(ref)
        }
    }

    /// 取消置顶 / 关闭面板时调用：把 ⌘1–9 还给系统和目标 App。幂等。
    func unregisterQuickPasteDigitHotkeys() {
        for ref in quickPasteDigitRefs where ref != nil {
            UnregisterEventHotKey(ref!)
        }
        quickPasteDigitRefs.removeAll()
    }

    private func startDoubleTapDetector() {
        let detector = DoubleTapDetector.shared
        detector.onDoubleTap = { [weak self] in
            self?.toggleQuickPanel()
        }
        detector.start()
    }

    private func unregisterHotKey() {
        guard let ref = hotKeyRef else { return }
        UnregisterEventHotKey(ref)
        hotKeyRef = nil
    }

    func toggleQuickPanel() {
        if QuickPanelWindowController.shared.isVisible {
            hideQuickPanel()
        } else {
            showQuickPanel()
        }
    }

    func showQuickPanel() {
        isQuickPanelVisible = true
        QuickPanelWindowController.shared.show(
            clipboardManager: ClipboardManager.shared,
            modelContainer: PasteMemoApp.sharedModelContainer
        )
    }

    func hideQuickPanel() {
        isQuickPanelVisible = false
        // 用户主动关闭（Esc / 关闭按钮 / 切到主窗口等都走这里），置顶也要关
        QuickPanelWindowController.shared.dismiss(force: true)
    }
}

// MARK: - HotkeyControllable

extension HotkeyManager: HotkeyControllable {
    func disableHotkey() {
        unregister()
    }

    func enableHotkey() {
        register()
    }
}
