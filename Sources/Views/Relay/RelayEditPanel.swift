import AppKit

/// Floating edit panel for relay queue items. Does not activate the app or show the main window.
enum RelayEditPanel {
    @MainActor private static var panel: NSPanel?

    @MainActor
    static func show(content: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        close()

        let panelWidth: CGFloat = 300
        let panelHeight: CGFloat = 160

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = L10n.tr("relay.editItem")
        panel.level = .floating + 1
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.center()

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))

        // Text view with scroll
        let textView = NSTextView(frame: .zero)
        textView.string = content
        textView.font = .systemFont(ofSize: 13)
        textView.isEditable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 50, width: panelWidth - 32, height: panelHeight - 66))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        contentView.addSubview(scrollView)

        // Buttons
        let saveBtn = NSButton(title: L10n.tr("action.save"), target: nil, action: nil)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: panelWidth - 90, y: 12, width: 74, height: 28)
        saveBtn.target = ButtonHandler.shared
        saveBtn.action = #selector(ButtonHandler.save)
        contentView.addSubview(saveBtn)

        let cancelBtn = NSButton(title: L10n.tr("action.cancel"), target: nil, action: nil)
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.frame = NSRect(x: panelWidth - 170, y: 12, width: 74, height: 28)
        cancelBtn.target = ButtonHandler.shared
        cancelBtn.action = #selector(ButtonHandler.cancel)
        contentView.addSubview(cancelBtn)

        panel.contentView = contentView
        self.panel = panel

        ButtonHandler.shared.configure(panel: panel, textView: textView, onSave: onSave, onCancel: onCancel)

        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(textView)
    }

    @MainActor static func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
private class ButtonHandler: NSObject {
    static let shared = ButtonHandler()

    private var panel: NSPanel?
    private var textView: NSTextView?
    private var onSave: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    func configure(panel: NSPanel, textView: NSTextView, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.panel = panel
        self.textView = textView
        self.onSave = onSave
        self.onCancel = onCancel
    }

    @objc func save() {
        let content = textView?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        panel?.orderOut(nil)
        if !content.isEmpty { onSave?(content) }
        cleanup()
    }

    @objc func cancel() {
        panel?.orderOut(nil)
        onCancel?()
        cleanup()
    }

    private func cleanup() {
        panel = nil
        textView = nil
        onSave = nil
        onCancel = nil
    }
}
