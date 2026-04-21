import SwiftUI

@MainActor
enum CommandAction: Hashable {
    case paste
    /// Paste the item, then delete it from history with an 8s undo window.
    /// Intended for one-shot values (OTP codes, temporary tokens) that should
    /// leave no trace after use. Suppressed for pinned / favourited items and
    /// for clips in a group flagged `preservesItems`.
    case pasteAndDestroy
    case cmdEnter(label: String)
    case copyColorFormat(format: String, label: String)
    case retryOCR
    case openInPreview
    case showInFinder
    case copy
    case transform(RuleAction)
    case addToRelay
    case splitAndRelay
    case pin(isPinned: Bool)
    case toggleSensitive(isSensitive: Bool)
    case delete
    /// Trigger a manual-trigger automation rule. Carries the rule's ID so the
    /// host can refetch and execute without keeping a SwiftData reference in
    /// a Hashable enum.
    case runRule(ruleID: String, displayName: String)

    var icon: String {
        switch self {
        case .paste: "doc.on.clipboard"
        case .pasteAndDestroy: "flame"
        case .cmdEnter: "textformat"
        case .copyColorFormat: "paintpalette"
        case .retryOCR: "text.viewfinder"
        case .openInPreview: "photo.on.rectangle.angled"
        case .showInFinder: "folder"
        case .copy: "doc.on.doc"
        case .transform: "wand.and.stars"
        case .addToRelay: "arrow.right.arrow.left"
        case .splitAndRelay: "scissors"
        case .pin(let pinned): pinned ? "pin.slash" : "pin"
        case .toggleSensitive(let sensitive): sensitive ? "lock.open" : "lock.shield"
        case .delete: "trash"
        case .runRule: "sparkles"
        }
    }

    var label: String {
        switch self {
        case .paste: L10n.tr("cmd.paste")
        case .pasteAndDestroy: L10n.tr("cmd.pasteAndDestroy")
        case .cmdEnter(let label): label
        case .copyColorFormat(_, let label): label
        case .retryOCR: L10n.tr("cmd.retryOCR")
        case .openInPreview: L10n.tr("cmd.openInPreview")
        case .showInFinder: L10n.tr("cmd.showInFinder")
        case .copy: L10n.tr("cmd.copy")
        case .transform(let action): action.displayLabel
        case .addToRelay: L10n.tr("relay.addToQueue")
        case .splitAndRelay: L10n.tr("relay.splitAndRelay")
        case .pin(let pinned): pinned ? L10n.tr("action.unpin") : L10n.tr("action.pin")
        case .toggleSensitive(let sensitive): sensitive ? L10n.tr("sensitive.unmarkSensitive") : L10n.tr("sensitive.markSensitive")
        case .delete: L10n.tr("cmd.delete")
        case .runRule(_, let displayName): displayName
        }
    }

    var shortcutKey: String? {
        switch self {
        case .paste: "V"
        case .pasteAndDestroy: "B"
        case .cmdEnter: "P"
        case .copyColorFormat: "P"
        case .retryOCR: "Y"
        case .openInPreview: "L"
        case .showInFinder: "O"
        case .copy: "C"
        case .transform: nil
        case .addToRelay: "R"
        case .splitAndRelay: "S"
        case .pin: "T"
        case .toggleSensitive: "E"
        case .delete: "D"
        case .runRule: nil
        }
    }

    var keyCode: Int? {
        switch self {
        case .paste: 9       // V
        case .pasteAndDestroy: 11 // B
        case .cmdEnter: 35   // P
        case .copyColorFormat: 35 // P
        case .retryOCR: 16   // Y
        case .openInPreview: 37 // L
        case .showInFinder: 31 // O
        case .copy: 8        // C
        case .transform: nil
        case .addToRelay: 15 // R
        case .splitAndRelay: 1 // S
        case .pin: 17        // T
        case .toggleSensitive: 14 // E
        case .delete: 2      // D
        case .runRule: nil
        }
    }

    var isDestructive: Bool {
        switch self {
        case .delete, .pasteAndDestroy: true
        default: false
        }
    }
}

// MARK: - Command Palette Content (popover body)

struct CommandPaletteContent: View {
    let item: ClipItem?
    let isMultiSelected: Bool
    /// Manual-trigger rules shown inline in the palette. Capped to 5 at the
    /// call site so a big rule list doesn't drown out built-in actions.
    var manualRules: [AutomationRule] = []
    /// Group names flagged `preservesItems` at the moment the palette opened.
    /// Used to suppress `pasteAndDestroy` for items whose group forbids deletion.
    var preservedGroupNames: Set<String> = []
    let onAction: (CommandAction) -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex = 0
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var isOptionPressed = false

    // keyCodes for digits 1..5 on an ANSI keyboard
    private static let digitKeyCodes: [Int] = [18, 19, 20, 21, 23]

    /// True when the current single-selection item can be paste-and-destroyed.
    /// Intentionally gated on single selection: multi-select paste-and-destroy is
    /// ambiguous (delete every selected item? only the active one?) so we skip it
    /// in that mode. Also suppressed for pinned / favourited items and for items
    /// whose group opts out of deletion via `SmartGroup.preservesItems`.
    private var canPasteAndDestroy: Bool {
        guard !isMultiSelected, let item else { return false }
        if item.isPinned || item.isFavorite { return false }
        if let group = item.groupName, !group.isEmpty, preservedGroupNames.contains(group) {
            return false
        }
        return true
    }

    private var actions: [CommandAction] {
        var list: [CommandAction] = [.paste]
        if canPasteAndDestroy {
            list.append(.pasteAndDestroy)
        }
        if let item, item.contentType == .color, let parsed = ColorConverter.parse(item.content) {
            let alt = parsed.alternateFormat
            let altValue = parsed.formatted(alt)
            list.append(.copyColorFormat(
                format: altValue,
                label: L10n.tr("cmd.copyAs", alt.rawValue)
            ))
        } else if let item, item.contentType != .color {
            list.append(.cmdEnter(label: cmdEnterLabel(for: item)))
        }
        if !isMultiSelected,
           let item,
           OCRTaskCoordinator.shared.canRetry(item: item) {
            list.append(.retryOCR)
        }
        if !isMultiSelected,
           let item,
           canOpenInPreview(item) {
            list.append(.openInPreview)
        }
        if let item, item.contentType.isFileBased {
            list.append(.showInFinder)
        }
        list.append(.copy)
        list.append(.addToRelay)
        if !isMultiSelected, let item, !item.content.isEmpty {
            list.append(.splitAndRelay)
        }
        let isPinned = isMultiSelected ? false : (item?.isPinned ?? false)
        let isSensitive = isMultiSelected ? false : (item?.isSensitive ?? false)
        list.append(.pin(isPinned: isPinned))
        list.append(.toggleSensitive(isSensitive: isSensitive))
        list.append(.delete)
        // Manual-trigger automation rules, appended after built-in actions so
        // they don't displace high-use commands (Paste, Copy, etc).
        for rule in manualRules {
            let displayName = rule.isBuiltIn ? L10n.tr(rule.name) : rule.name
            list.append(.runRule(ruleID: rule.ruleID, displayName: displayName))
        }
        return list
    }

    /// Digit shortcut to display next to a rule row (1-indexed). Only rules
    /// map to digits 1–5; earlier built-in commands keep their letter keys.
    private func digitForAction(at index: Int) -> String? {
        let action = actions[index]
        guard case .runRule = action else { return nil }
        let ruleIndex = actions[..<index].reduce(0) { count, a in
            if case .runRule = a { return count + 1 }
            return count
        }
        guard ruleIndex < Self.digitKeyCodes.count else { return nil }
        return String(ruleIndex + 1)
    }

    private func cmdEnterLabel(for item: ClipItem) -> String {
        switch item.contentType {
        case .text, .code, .color, .email, .phone, .mixed:
            L10n.tr("cmd.pasteAsPlainText")
        case .link: L10n.tr("cmd.openLink")
        case .image, .file, .document, .archive, .application, .video, .audio:
            L10n.tr("cmd.pastePath")
        }
    }

    private func canOpenInPreview(_ item: ClipItem) -> Bool {
        QuickLookHelper.shared.canOpenInPreview(item: item)
    }

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                commandRow(action: action, isSelected: selectedIndex == index, index: index)
                    .onTapGesture { execute(action) }
                    .onHover { if $0 { selectedIndex = index } }
            }
        }
        .padding(5)
        .frame(width: 200)
        .onAppear {
            installKeyMonitor()
            installFlagsMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
            removeFlagsMonitor()
        }
    }

    private func displayLabel(for action: CommandAction) -> String {
        let suffix = isOptionPressed ? L10n.tr("cmd.andNewLine") : ""
        switch action {
        case .paste, .cmdEnter: return action.label + suffix
        default: return action.label
        }
    }

    private func commandRow(action: CommandAction, isSelected: Bool, index: Int) -> some View {
        let isRuleRow: Bool = {
            if case .runRule = action { return true }
            return false
        }()
        let ruleDigit = digitForAction(at: index)
        return HStack(spacing: 8) {
            Image(systemName: action.icon)
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(
                    action.isDestructive ? .red : (isRuleRow ? .purple : .secondary)
                )
            Text(displayLabel(for: action))
                .font(.system(size: 12))
                .foregroundStyle(action.isDestructive ? .red : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if let key = action.shortcutKey ?? ruleDigit {
                Text(key)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
    }

    private func execute(_ action: CommandAction) {
        removeKeyMonitor()
        removeFlagsMonitor()
        onAction(action)
        onDismiss()
    }

    private func dismiss() {
        removeKeyMonitor()
        removeFlagsMonitor()
        onDismiss()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            let hasControl = event.modifierFlags.contains(.control)
            switch code {
            case 53: dismiss(); return nil // Esc
            case 40 where event.modifierFlags.contains(.command): dismiss(); return nil // Cmd+K
            case 13 where event.modifierFlags.contains(.command): dismiss(); return nil // Cmd+W
            case 126: // Up
                selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : actions.count - 1; return nil
            case 125: // Down
                selectedIndex = selectedIndex < actions.count - 1 ? selectedIndex + 1 : 0; return nil
            case 35: // P
                if hasControl {
                    selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : actions.count - 1
                    return nil
                }
                return event
            case 45: // N
                if hasControl {
                    selectedIndex = selectedIndex < actions.count - 1 ? selectedIndex + 1 : 0
                    return nil
                }
                return event
            case 36: execute(actions[selectedIndex]); return nil // Enter
            default:
                if let match = actions.first(where: { $0.keyCode == code }) {
                    execute(match); return nil
                }
                // Digits 1–5 trigger the Nth manual-trigger rule inline.
                if let digitIndex = Self.digitKeyCodes.firstIndex(of: code) {
                    let ruleActions = actions.filter {
                        if case .runRule = $0 { return true }
                        return false
                    }
                    if digitIndex < ruleActions.count {
                        execute(ruleActions[digitIndex])
                        return nil
                    }
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func installFlagsMonitor() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            isOptionPressed = event.modifierFlags.contains(.option)
            return event
        }
    }

    private func removeFlagsMonitor() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
    }
}
