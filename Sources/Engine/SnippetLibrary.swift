import AppKit
import SwiftData

enum SnippetSaveChoice {
    case createNew
    case updateExisting
    case cancel
}

struct SnippetSaveInput {
    let title: String
}

@MainActor
private final class SnippetTitlePromptPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let input: NSTextField
    private var response: NSApplication.ModalResponse = .cancel

    init(title: String, placeholder: String) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 122),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        input = NSTextField(frame: .zero)
        super.init()

        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.delegate = self

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 122))
        contentView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = contentView

        input.translatesAutoresizingMaskIntoConstraints = false
        input.placeholderString = placeholder

        let saveButton = NSButton(title: L10n.tr("action.save"), target: self, action: #selector(handleSave))
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: L10n.tr("action.cancel"), target: self, action: #selector(handleCancel))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"

        contentView.addSubview(input)
        contentView.addSubview(saveButton)
        contentView.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            input.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            input.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            cancelButton.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            saveButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8)
        ])

        panel.initialFirstResponder = input
        panel.defaultButtonCell = saveButton.cell as? NSButtonCell
    }

    func run() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        input.selectText(nil)
        let modalResponse = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return modalResponse == .OK ? input.stringValue : nil
    }

    func windowWillClose(_ notification: Notification) {
        if response == .cancel {
            NSApp.stopModal(withCode: .cancel)
        }
    }

    @objc private func handleSave() {
        response = .OK
        NSApp.stopModal(withCode: .OK)
        panel.close()
    }

    @objc private func handleCancel() {
        response = .cancel
        NSApp.stopModal(withCode: .cancel)
        panel.close()
    }
}

extension Notification.Name {
    static let snippetDidUpdate = Notification.Name("SnippetLibraryDidUpdate")
    static let snippetShouldOpenInManager = Notification.Name("SnippetShouldOpenInManager")
}

@MainActor
enum SnippetLibrary {
    static func createEmpty(in context: ModelContext) -> SnippetItem {
        let snippet = SnippetItem()
        context.insert(snippet)
        saveAndNotify(context)
        return snippet
    }

    static func createSnippet(from item: ClipItem, title: String? = nil, in context: ModelContext) -> SnippetItem {
        let snippet = SnippetItem(
            title: resolvedTitle(for: item, customTitle: title),
            content: item.content,
            contentType: item.contentType,
            groupName: item.groupName,
            isPinned: item.isPinned,
            richTextData: item.richTextData,
            richTextType: item.richTextType
        )
        context.insert(snippet)
        saveAndNotify(context)
        return snippet
    }

    static func suggestedTitle(for item: ClipItem) -> String {
        (item.displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? item.content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
            ?? L10n.tr("snippet.untitled")
    }

    static func resolvedTitle(for item: ClipItem, customTitle: String?) -> String {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? suggestedTitle(for: item) : trimmed
    }

    static func findDuplicate(for item: ClipItem, in context: ModelContext) -> SnippetItem? {
        let descriptor = FetchDescriptor<SnippetItem>()
        let snippets = (try? context.fetch(descriptor)) ?? []
        return snippets.first { snippet in
            snippet.content == item.content
        }
    }

    static func update(_ snippet: SnippetItem, from item: ClipItem, title: String, in context: ModelContext) {
        snippet.title = title
        snippet.content = item.content
        snippet.contentType = item.contentType
        snippet.richTextData = item.richTextData
        snippet.richTextType = item.richTextType
        saveAndNotify(context)
    }

    @discardableResult
    static func saveSnippet(
        from item: ClipItem,
        title customTitle: String? = nil,
        in context: ModelContext,
        chooseDuplicate: (SnippetItem) -> SnippetSaveChoice
    ) -> SnippetItem? {
        let finalTitle = resolvedTitle(for: item, customTitle: customTitle)

        if let duplicate = findDuplicate(for: item, in: context) {
            switch chooseDuplicate(duplicate) {
            case .updateExisting:
                update(duplicate, from: item, title: finalTitle, in: context)
                return duplicate
            case .createNew:
                break
            case .cancel:
                return nil
            }
        }

        return createSnippet(from: item, title: finalTitle, in: context)
    }

    static func promptForTitle(for item: ClipItem) -> SnippetSaveInput? {
        let panel = SnippetTitlePromptPanel(
            title: L10n.tr("snippet.saveAs"),
            placeholder: suggestedTitle(for: item)
        )
        guard let title = panel.run() else {
            return nil
        }
        return SnippetSaveInput(title: title)
    }

    static func saveAndNotify(_ context: ModelContext) {
        try? context.save()
        NotificationCenter.default.post(name: .snippetDidUpdate, object: nil)
    }

    static func writeToPasteboard(_ snippet: SnippetItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snippet.content, forType: .string)

        if let richTextData = snippet.richTextData {
            let type: NSPasteboard.PasteboardType = snippet.richTextType == "html" ? .html : .rtf
            pasteboard.setData(richTextData, forType: type)
        }
    }

    static func copyToClipboard(_ snippet: SnippetItem) {
        writeToPasteboard(snippet)
    }

    static func markUsed(_ snippet: SnippetItem, in context: ModelContext) {
        snippet.lastUsedAt = Date()
        snippet.usageCount += 1
        saveAndNotify(context)
    }

    static func openInManager(_ snippetID: PersistentIdentifier) {
        AppAction.shared.openMainWindow?()
        NotificationCenter.default.post(name: .snippetShouldOpenInManager, object: snippetID)
    }
}
