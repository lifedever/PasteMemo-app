import AppKit
import Carbon

/// Modifier keys available for double-tap detection.
enum DoubleTapModifier: Int, CaseIterable {
    case command = 0
    case shift = 1
    case control = 2
    case option = 3

    var label: String {
        switch self {
        case .command: "⌘ Command"
        case .shift: "⇧ Shift"
        case .control: "⌃ Control"
        case .option: "⌥ Option"
        }
    }

    /// The NSEvent modifier flag for this key.
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: .command
        case .shift: .shift
        case .control: .control
        case .option: .option
        }
    }
}

/// Detects double-tap of a modifier key via global flagsChanged events.
/// Calls `onDoubleTap` when a modifier key is pressed twice within the threshold interval.
@MainActor
final class DoubleTapDetector {
    static let shared = DoubleTapDetector()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastTapTime: TimeInterval = 0
    private var lastModifier: NSEvent.ModifierFlags = []
    private var isKeyDown = false

    private let tapInterval: TimeInterval = 0.3

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "doubleTapEnabled")
    }

    var selectedModifier: DoubleTapModifier {
        let raw = UserDefaults.standard.integer(forKey: "doubleTapModifier")
        return DoubleTapModifier(rawValue: raw) ?? .command
    }

    var onDoubleTap: (() -> Void)?

    private init() {}

    func start() {
        stop()
        guard isEnabled else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlagsChanged(event)
            }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        resetState()
    }

    func restart() {
        stop()
        start()
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let targetFlag = selectedModifier.flag
        let isTargetDown = event.modifierFlags.contains(targetFlag)

        // Only react when ONLY the target modifier is pressed (no combos)
        let otherModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
            .filter { $0 != targetFlag }
            .reduce(NSEvent.ModifierFlags()) { $0.union($1) }
        let hasOtherModifiers = !event.modifierFlags.intersection(otherModifiers).isEmpty

        if hasOtherModifiers {
            resetState()
            return
        }

        if isTargetDown && !isKeyDown {
            // Key just pressed
            isKeyDown = true
            let now = ProcessInfo.processInfo.systemUptime

            if lastModifier == targetFlag && (now - lastTapTime) < tapInterval {
                // Double tap detected
                onDoubleTap?()
                resetState()
            } else {
                lastTapTime = now
                lastModifier = targetFlag
            }
        } else if !isTargetDown && isKeyDown {
            // Key released
            isKeyDown = false
        }
    }

    private func resetState() {
        lastTapTime = 0
        lastModifier = []
        isKeyDown = false
    }
}
