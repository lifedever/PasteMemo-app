import SwiftUI

@MainActor
enum CommandAction: Hashable {
    case paste
    case cmdEnter(label: String)
    case copyColorFormat(format: String, label: String)
    case retryOCR
    case openInPreview
    case showInFinder
    case copy
    case saveAsSnippet
    case transform(RuleAction)
    case addToRelay
    case splitAndRelay
    case openSnippetInManager
    case pin(isPinned: Bool)
    case toggleSensitive(isSensitive: Bool)
    case delete

    var icon: String {
        switch self {
        case .paste: "doc.on.clipboard"
        case .cmdEnter: "textformat"
        case .copyColorFormat: "paintpalette"
        case .retryOCR: "text.viewfinder"
        case .openInPreview: "photo.on.rectangle.angled"
        case .showInFinder: "folder"
        case .copy: "doc.on.doc"
        case .saveAsSnippet: "bookmark"
        case .transform: "wand.and.stars"
        case .addToRelay: "arrow.right.arrow.left"
        case .splitAndRelay: "scissors"
        case .openSnippetInManager: "sidebar.left"
        case .pin(let pinned): pinned ? "pin.slash" : "pin"
        case .toggleSensitive(let sensitive): sensitive ? "lock.open" : "lock.shield"
        case .delete: "trash"
        }
    }

    var label: String {
        switch self {
        case .paste: L10n.tr("cmd.paste")
        case .cmdEnter(let label): label
        case .copyColorFormat(_, let label): label
        case .retryOCR: L10n.tr("cmd.retryOCR")
        case .openInPreview: L10n.tr("cmd.openInPreview")
        case .showInFinder: L10n.tr("cmd.showInFinder")
        case .copy: L10n.tr("cmd.copy")
        case .saveAsSnippet: L10n.tr("snippet.saveAs")
        case .transform(let action): action.displayLabel
        case .addToRelay: L10n.tr("relay.addToQueue")
        case .splitAndRelay: L10n.tr("relay.splitAndRelay")
        case .openSnippetInManager: L10n.tr("quick.openManager")
        case .pin(let pinned): pinned ? L10n.tr("action.unpin") : L10n.tr("action.pin")
        case .toggleSensitive(let sensitive): sensitive ? L10n.tr("sensitive.unmarkSensitive") : L10n.tr("sensitive.markSensitive")
        case .delete: L10n.tr("cmd.delete")
        }
    }

    var shortcutKey: String? {
        switch self {
        case .paste: "V"
        case .cmdEnter: "P"
        case .copyColorFormat: "P"
        case .retryOCR: "Y"
        case .openInPreview: "L"
        case .showInFinder: "O"
        case .copy: "C"
        case .saveAsSnippet: "N"
        case .transform: nil
        case .addToRelay: "R"
        case .splitAndRelay: "S"
        case .openSnippetInManager: "M"
        case .pin: "T"
        case .toggleSensitive: "E"
        case .delete: "D"
        }
    }

    var keyCode: Int? {
        switch self {
        case .paste: 9       // V
        case .cmdEnter: 35   // P
        case .copyColorFormat: 35 // P
        case .retryOCR: 16   // Y
        case .openInPreview: 37 // L
        case .showInFinder: 31 // O
        case .copy: 8        // C
        case .saveAsSnippet: 45 // N
        case .transform: nil
        case .addToRelay: 15 // R
        case .splitAndRelay: 1 // S
        case .openSnippetInManager: 46 // M
        case .pin: 17        // T
        case .toggleSensitive: 14 // E
        case .delete: 2      // D
        }
    }

    var isDestructive: Bool {
        if case .delete = self { return true }
        return false
    }
}

// MARK: - Command Palette Content (popover body)

struct CommandPaletteContent: View {
    let item: ClipItem?
    let snippet: SnippetItem?
    let isMultiSelected: Bool
    let onAction: (CommandAction) -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex = 0
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var isOptionPressed = false

    private var actions: [CommandAction] {
        if let snippet {
            var list: [CommandAction] = [.paste, .copy]
            if !snippet.content.isEmpty {
                list.append(.addToRelay)
                list.append(.splitAndRelay)
            }
            list.append(.openSnippetInManager)
            list.append(.pin(isPinned: snippet.isPinned))
            list.append(.delete)
            return list
        }

        var list: [CommandAction] = [.paste]
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
        if !isMultiSelected, item != nil {
            list.append(.saveAsSnippet)
        }
        list.append(.addToRelay)
        if !isMultiSelected, let item, !item.content.isEmpty {
            list.append(.splitAndRelay)
        }
        let isPinned = isMultiSelected ? false : (item?.isPinned ?? false)
        let isSensitive = isMultiSelected ? false : (item?.isSensitive ?? false)
        list.append(.pin(isPinned: isPinned))
        list.append(.toggleSensitive(isSensitive: isSensitive))
        list.append(.delete)
        return list
    }

    private func cmdEnterLabel(for item: ClipItem) -> String {
        switch item.contentType {
        case .text, .code, .color, .email, .phone:
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
                commandRow(action: action, isSelected: selectedIndex == index)
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

    private func commandRow(action: CommandAction, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: action.icon)
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(action.isDestructive ? .red : .secondary)
            Text(displayLabel(for: action))
                .font(.system(size: 12))
                .foregroundStyle(action.isDestructive ? .red : .primary)
            Spacer()
            if let key = action.shortcutKey {
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
