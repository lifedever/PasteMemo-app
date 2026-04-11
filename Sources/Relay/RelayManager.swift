import AppKit
import Observation

@MainActor
@Observable
final class RelayManager {

    static let shared = RelayManager()
    static let MAX_QUEUE_SIZE = 500

    var items: [RelayItem] = []
    var currentIndex = 0
    var isActive = false
    var isPaused = false
    var autoExitOnEmpty = true
    var pasteAsPlainText = false

    weak var clipboardController: (any ClipboardControllable)?
    weak var hotkeyController: (any HotkeyControllable)?

    private init() {}

    // MARK: - Computed

    var isQueueExhausted: Bool {
        guard !items.isEmpty else { return true }
        return currentIndex >= items.count
    }

    var currentItem: RelayItem? {
        guard currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    var progressText: String {
        let done = items.prefix(currentIndex).count
        return "\(done)/\(items.count)"
    }

    // MARK: - Queue Management

    func enqueue(texts: [String]) {
        let capacity = Self.MAX_QUEUE_SIZE - items.count
        guard capacity > 0 else { return }
        let filtered = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !filtered.isEmpty else { return }
        let newItems = filtered.prefix(capacity).map { RelayItem(content: $0) }
        // Resize window first, then add items so panel expands before content appears
        windowController?.updateSize(for: items.count + newItems.count)
        items.append(contentsOf: newItems)
        markCurrentIfNeeded()
    }

    func enqueue(clipItems: [ClipItem]) {
        let capacity = Self.MAX_QUEUE_SIZE - items.count
        guard capacity > 0 else { return }
        let newItems: [RelayItem] = clipItems.prefix(capacity).compactMap { clip in
            // Pure image (screenshot/clipboard capture)
            if clip.contentType == .image, clip.content == "[Image]", let data = clip.imageData {
                return RelayItem(content: clip.content, imageData: data, contentKind: .image)
            }
            // File-based items (files copied from Finder, including image/video/audio files)
            if clip.contentType.isFileBased {
                let text = clip.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return RelayItem(content: text, contentKind: .file)
            }
            // Plain text
            let text = clip.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RelayItem(content: text)
        }
        guard !newItems.isEmpty else { return }
        windowController?.updateSize(for: items.count + newItems.count)
        items.append(contentsOf: newItems)
        markCurrentIfNeeded()
    }

    /// Paste current item and advance. Returns the item to paste, or nil if exhausted.
    func advance() -> RelayItem? {
        guard currentIndex < items.count else { return nil }
        let item = items[currentIndex]
        items[currentIndex].state = .done
        currentIndex += 1
        if currentIndex < items.count {
            items[currentIndex].state = .current
        }
        return item
    }

    func skip() {
        guard currentIndex < items.count else { return }
        items[currentIndex].state = .skipped
        currentIndex += 1
        if currentIndex < items.count {
            items[currentIndex].state = .current
        }
    }

    func rollback() {
        guard currentIndex > 0 else { return }
        if currentIndex < items.count {
            items[currentIndex].state = .pending
        }
        currentIndex -= 1
        items[currentIndex].state = .current
    }

    func deleteItem(at index: Int) {
        guard index >= 0, index < items.count else { return }

        let removedWasCurrent = index == currentIndex
        items.remove(at: index)
        windowController?.updateSize(for: items.count)

        if items.isEmpty {
            currentIndex = 0
            return
        }

        if index < currentIndex {
            currentIndex -= 1
        } else if removedWasCurrent {
            currentIndex = min(currentIndex, items.count - 1)
            for itemIndex in items.indices where items[itemIndex].state == .current {
                items[itemIndex].state = .pending
            }
        }

        if currentIndex >= items.count {
            currentIndex = items.count - 1
        }
        markCurrentIfNeeded()
    }

    func clearAll() {
        items.removeAll()
        currentIndex = 0
        windowController?.updateSize(for: 0)
    }

    func updateItem(at index: Int, content: String) {
        guard index >= 0, index < items.count else { return }
        items[index].content = content
    }

    func reverseItems() {
        for i in items.indices { items[i].state = .pending }
        items.reverse()
        currentIndex = 0
        if !items.isEmpty { items[0].state = .current }
    }

    func moveItem(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        // After reorder, recalculate current to first non-done item
        for i in items.indices where items[i].state == .current {
            items[i].state = .pending
        }
        if let idx = items.firstIndex(where: { $0.state != .done && $0.state != .skipped }) {
            items[idx].state = .current
            currentIndex = idx
        }
    }

    func splitItem(at index: Int, by delimiter: RelayDelimiter) -> Bool {
        guard let parts = RelaySplitter.split(items[index].content, by: delimiter) else {
            return false
        }
        let wasCurrent = items[index].state == .current
        let newItems = parts.map { RelayItem(content: $0) }
        let newCount = items.count + newItems.count - 1
        windowController?.updateSize(for: newCount)
        items.replaceSubrange(index...index, with: newItems)
        if wasCurrent {
            items[index].state = .current
            currentIndex = index
        } else if index < currentIndex {
            currentIndex += newItems.count - 1
        }
        return true
    }

    // MARK: - Activation Alert

    private func showActivationAlert() {
        guard !UserDefaults.standard.bool(forKey: "relayAlertDismissed") else { return }
        let handler = RelayHotkeyHandler()
        let shortcut = shortcutDisplayString(keyCode: handler.pasteKeyCode, modifiers: handler.pasteModifiers)
        let alert = NSAlert()
        alert.messageText = L10n.tr("relay.alert.title")
        alert.informativeText = L10n.tr("relay.alert.message", shortcut)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr("relay.alert.ok"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L10n.tr("relay.alert.dontShowAgain")
        // Temporarily become regular app so alert gets proper focus and centering
        let hideDock = UserDefaults.standard.bool(forKey: "hideDockIcon")
        if !hideDock {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        if !hideDock {
            NSApp.setActivationPolicy(.accessory)
        }
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: "relayAlertDismissed")
        }
    }

    // MARK: - Components

    private var monitor: RelayClipboardMonitor?
    private var hotkeyHandler: RelayHotkeyHandler?
    private var windowController: RelayFloatingWindowController?
    private var wasMonitoringPausedBeforeRelay = false

    // MARK: - Mode Lifecycle

    func activate() {
        guard !isActive else { return }
        isActive = true
        wasMonitoringPausedBeforeRelay = clipboardController?.isMonitoringPaused ?? false
        clipboardController?.pauseMonitoring()
        hotkeyController?.disableHotkey()
        // Defensive: ensure quick panel hotkey is fully unregistered
        HotkeyManager.shared.unregister()
        startMonitor()
        startHotkeys()
        showWindow()
        // Show alert after window appears, non-blocking
        DispatchQueue.main.async { [weak self] in
            self?.showActivationAlert()
        }
    }

    func pause() {
        guard isActive, !isPaused else { return }
        isPaused = true
        stopMonitor()
        stopHotkeys()
        if !wasMonitoringPausedBeforeRelay {
            clipboardController?.resumeMonitoring()
        }
        HotkeyManager.shared.register()
    }

    func resume() {
        guard isActive, isPaused else { return }
        isPaused = false
        clipboardController?.pauseMonitoring()
        HotkeyManager.shared.unregister()
        QuickPanelWindowController.shared.dismiss()
        startMonitor()
        startHotkeys()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        isPaused = false
        stopMonitor()
        stopHotkeys()
        QuickPanelWindowController.shared.dismiss()
        dismissWindow()
        items.removeAll()
        currentIndex = 0
        if !wasMonitoringPausedBeforeRelay {
            clipboardController?.resumeMonitoring()
        }
        hotkeyController?.enableHotkey()
        HotkeyManager.shared.register()
    }

    // MARK: - Orchestration

    private func startMonitor() {
        let mon = RelayClipboardMonitor()
        mon.onNewContent = { [weak self] text in
            self?.enqueue(texts: [text])
        }
        mon.start()
        monitor = mon
    }

    private func stopMonitor() {
        monitor?.stop()
        monitor = nil
    }

    private func startHotkeys() {
        let handler = RelayHotkeyHandler()
        RelayHotkeyHandler.current = handler
        handler.onPaste = { [weak self] in
            Task { @MainActor in self?.pasteNext() }
        }
        handler.onSkip = { [weak self] in
            Task { @MainActor in self?.skip() }
        }
        handler.onPrevious = { [weak self] in
            Task { @MainActor in self?.rollback() }
        }
        handler.start()
        hotkeyHandler = handler
    }

    private func stopHotkeys() {
        hotkeyHandler?.stop()
        RelayHotkeyHandler.current = nil
        hotkeyHandler = nil
    }

    func pauseHotkeys() { hotkeyHandler?.stop() }
    func resumeHotkeys() { hotkeyHandler?.start() }

    private func showWindow() {
        let controller = RelayFloatingWindowController(relayManager: self)
        controller.show()
        windowController = controller
    }

    private func dismissWindow() {
        windowController?.dismiss()
        windowController = nil
    }

    private func pasteNext() {
        guard let item = advance() else {
            handleQueueExhausted()
            return
        }
        guard let mon = monitor else { return }
        Task {
            if pasteAsPlainText {
                await RelayPaster.paste(item.content, monitor: mon)
            } else {
                switch item.contentKind {
                case .image:
                    if let imageData = item.imageData {
                        await RelayPaster.pasteImage(imageData, monitor: mon)
                    } else {
                        await RelayPaster.paste(item.content, monitor: mon)
                    }
                case .file:
                    await RelayPaster.pasteFile(item.content, monitor: mon)
                case .text:
                    await RelayPaster.paste(item.content, monitor: mon)
                }
            }
            SoundManager.playPaste()
            // Check if queue just became exhausted after this paste
            if isQueueExhausted {
                handleQueueExhausted()
            }
        }
    }

    private func handleQueueExhausted() {
        NSSound(named: "Glass")?.play()
        if autoExitOnEmpty {
            deactivate()
        }
    }

    // MARK: - Private

    private func markCurrentIfNeeded() {
        guard !items.isEmpty else { return }
        guard items.first(where: { $0.state == .current }) == nil else { return }
        if let idx = items.firstIndex(where: { $0.state == .pending }) {
            items[idx].state = .current
            currentIndex = idx
        }
    }
}
