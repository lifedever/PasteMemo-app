import SwiftUI
import Carbon

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    var onChanged: (() -> Void)?

    init(keyCode: Binding<Int>, modifiers: Binding<Int>, onChanged: (() -> Void)? = nil) {
        _keyCode = keyCode
        _modifiers = modifiers
        self.onChanged = onChanged
    }

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let field = ShortcutRecorderField()
        field.onShortcutChanged = { code, mods in
            keyCode = code
            modifiers = mods
            onChanged?()
        }
        field.updateDisplay(keyCode: keyCode, modifiers: modifiers)
        return field
    }

    func updateNSView(_ field: ShortcutRecorderField, context: Context) {
        field.updateDisplay(keyCode: keyCode, modifiers: modifiers)
    }
}

class ShortcutRecorderField: NSTextField {
    var onShortcutChanged: ((Int, Int) -> Void)?
    private var isRecording = false
    private var localMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .center
        font = .systemFont(ofSize: 13)
        placeholderString = L10n.tr("settings.shortcut.clickToRecord")
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        stringValue = L10n.tr("settings.shortcut.pressKey")
        textColor = .systemOrange

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == 53 { // Escape
                self.stopRecording()
                return nil
            }

            let isFunctionKey = (0x60...0x7F).contains(Int(event.keyCode))
            // Require at least one modifier, unless it's a function key (F1-F12 etc.)
            if !isFunctionKey {
                guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else {
                    return nil
                }
            }

            let carbonMods = self.toCarbonModifiers(mods)
            self.onShortcutChanged?(Int(event.keyCode), carbonMods)
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        textColor = .labelColor
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    func updateDisplay(keyCode: Int, modifiers: Int) {
        guard !isRecording else { return }
        let display = shortcutDisplayString(keyCode: keyCode, modifiers: modifiers)
        stringValue = display.isEmpty ? "" : display
        placeholderString = display.isEmpty ? L10n.tr("settings.shortcut.clickToRecord") : L10n.tr("settings.shortcut.clickToRecord")
    }

    private func toCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.shift) { result |= shiftKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        return result
    }
}

func shortcutDisplayString(keyCode: Int, modifiers: Int) -> String {
    guard keyCode >= 0 && modifiers >= 0 else { return "" }
    var parts: [String] = []
    if modifiers & controlKey != 0 { parts.append("⌃") }
    if modifiers & optionKey != 0 { parts.append("⌥") }
    if modifiers & shiftKey != 0 { parts.append("⇧") }
    if modifiers & cmdKey != 0 { parts.append("⌘") }
    parts.append(keyName(for: keyCode))
    return parts.joined()
}

private func keyName(for keyCode: Int) -> String {
    let mapping: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "B", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "↵", 37: "L", 38: "J", 39: "'",
        40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "⇥", 49: "Space", 50: "`",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20",
    ]
    return mapping[keyCode] ?? "Key\(keyCode)"
}
