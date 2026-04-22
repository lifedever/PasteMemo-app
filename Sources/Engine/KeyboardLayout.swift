import AppKit
import Carbon.HIToolbox

/// Resolves the virtual-key code to synthesize for a given latin character under the
/// currently active keyboard layout. Needed because `virtualKey` is a *physical key
/// position* (ANSI layout) — hard-coding e.g. `0x09` assumes "V" lives at the ANSI V
/// slot, which is true for QWERTY but not for pure Dvorak / Colemak / AZERTY / etc.
/// Under those layouts, a synthesized `virtualKey = 0x09 + ⌘` becomes ⌘K (or whatever
/// character sits at the ANSI V slot in that layout), not ⌘V.
///
/// Dvorak-QWERTY-⌘ (the most common "Dvorak" variant on macOS) is unaffected because
/// the system temporarily switches to QWERTY whenever ⌘ is held — for those users the
/// ANSI-position keycode works as-is. Only pure Dvorak / Colemak users hit the bug.
enum KeyboardLayout {
    /// ANSI position of the V key. Fallback for when layout resolution fails and for
    /// QWERTY / Dvorak-QWERTY-⌘ where it is correct.
    static let ansiVKeyCode: UInt16 = UInt16(kVK_ANSI_V)

    /// Returns the virtual-key code that, under the current keyboard layout, produces
    /// a lowercase "v" character. Falls back to the ANSI V position if the layout
    /// cannot be inspected (Carbon APIs returning nil, missing unicode layout data, etc.).
    static func virtualKeyForV() -> UInt16 {
        virtualKey(for: "v") ?? ansiVKeyCode
    }

    /// Scans the active keyboard layout for the virtual-key code whose unmodified
    /// character matches `character`. Returns nil when the layout is unavailable or
    /// lacks a unicode mapping (older script-based layouts do, but those are extinct
    /// on modern macOS). Result is a cheap lookup — called at most once per paste.
    static func virtualKey(for character: Character) -> UInt16? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
        let target = String(character)

        return layoutData.withUnsafeBytes { rawBuffer -> UInt16? in
            guard let base = rawBuffer.baseAddress else { return nil }
            let keyLayoutPtr = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)

            // keycodes 0...127 cover every physical key on a standard Mac keyboard;
            // scanning all of them is a few microseconds.
            for code in 0..<128 {
                let status = UCKeyTranslate(
                    keyLayoutPtr,
                    UInt16(code),
                    UInt16(kUCKeyActionDisplay),
                    0,                                // no modifiers
                    UInt32(LMGetKbdType()),
                    UInt32(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                guard status == noErr, length > 0 else { continue }
                let produced = String(utf16CodeUnits: chars, count: length)
                if produced == target { return UInt16(code) }
            }
            return nil
        }
    }
}
