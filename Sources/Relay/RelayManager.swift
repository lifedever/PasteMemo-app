import AppKit
import Observation
import SwiftData

@MainActor
@Observable
final class RelayManager {

    static let shared = RelayManager()
    static let MAX_QUEUE_SIZE = 500

    var items: [RelayItem] = []
    var currentIndex = 0
    var lastRecirculation: RelayRecirculation.UndoHandle?
    private var lastRecirculationExpiry: Task<Void, Never>?
    var isActive = false
    var isPaused = false
    var autoExitOnEmpty = true
    var pasteAsPlainText: Bool {
        get { UserDefaults.standard.bool(forKey: "relayPasteAsPlainText") }
        set { UserDefaults.standard.set(newValue, forKey: "relayPasteAsPlainText") }
    }
    var loopEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "relayLoopEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "relayLoopEnabled") }
    }

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
        let newItems = clipItems.prefix(capacity).compactMap(RelayItem.from)
        guard !newItems.isEmpty else { return }
        windowController?.updateSize(for: items.count + newItems.count)
        items.append(contentsOf: newItems)
        markCurrentIfNeeded()
    }

    /// UI 入口：把 clip 加入接力队列。保证先激活（恢复持久化历史）再追加，避免
    /// "先 enqueue 再 activate" 导致新 items 被持久化 items 覆盖到后面、产生双 current 的 bug。
    /// 若本次是追加到已有队列（活跃中 或 从持久化恢复出来的历史），会弹出 toast 提示当前进度。
    func addToQueue(clipItems: [ClipItem]) {
        if !isActive {
            activate()
        }
        let hadHistory = !items.isEmpty
        enqueue(clipItems: clipItems)
        if hadHistory {
            ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("relay.appendedToQueue", currentIndex, items.count), icon: .info))
        }
    }

    func addToQueue(texts: [String]) {
        if !isActive {
            activate()
        }
        let hadHistory = !items.isEmpty
        enqueue(texts: texts)
        if hadHistory {
            ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("relay.appendedToQueue", currentIndex, items.count), icon: .info))
        }
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

    /// 跳转到任意条目作为新的当前行。
    /// - 前进跳跃：跨过的条目（旧 current 到目标前一项）置为 `.skipped`，等价于连按多次 skip。
    /// - 倒退跳跃：跨过的条目（目标后一项到旧 current）全部回到 `.pending`，等价于"重新处理这一段"。
    /// - 目标自身：直接设为 `.current`，原状态（done / skipped 等）被覆盖。
    func jumpTo(index: Int) {
        guard index >= 0, index < items.count, index != currentIndex else { return }
        if index > currentIndex {
            for i in currentIndex..<index where items[i].state != .done && items[i].state != .skipped {
                items[i].state = .skipped
            }
        } else {
            let upper = min(currentIndex, items.count - 1)
            for i in (index + 1)...upper {
                items[i].state = .pending
            }
        }
        currentIndex = index
        items[index].state = .current
    }

    func deleteItem(at index: Int) {
        guard index >= 0, index < items.count else { return }
        let removed = items[index]
        items.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex, currentIndex >= items.count, !items.isEmpty {
            currentIndex = items.count - 1
        }
        markCurrentIfNeeded()
        windowController?.updateSize(for: items.count)

        // Recirculate to clipboard history so the clip is not permanently lost. Skip
        // when inactive (e.g. unit tests, sharedModelContainer may point at user data).
        guard isActive else { return }
        let context = ModelContext(PasteMemoApp.sharedModelContainer)
        let handle = RelayRecirculation.recirculate(removed, originalIndex: index, context: context)
        try? context.save()
        scheduleRecirculationExpiry(handle)
    }

    func clearAll() {
        lastRecirculation = nil
        lastRecirculationExpiry?.cancel()
        lastRecirculationExpiry = nil
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
        let sourceBundle = items[index].sourceAppBundleID
        let newItems = parts.map { RelayItem(content: $0, sourceAppBundleID: sourceBundle) }
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
    /// Holds the most recently scheduled paste Task so new presses can chain
    /// after it and execute strictly one-at-a-time. Without this, rapid hotkey
    /// presses spawn concurrent Tasks that race on the shared pasteboard —
    /// Task N+1's pasteboard write overwrites Task N's before the target app
    /// has finished reading it (issue #28: Word pastes only the last snapshot).
    private var currentPasteTask: Task<Void, Never>?

    // MARK: - Mode Lifecycle

    func activate() {
        guard !isActive else { return }
        isActive = true

        if let persisted = RelayQueuePersistence.load() {
            for pItem in persisted.items {
                var item = RelayItem(
                    content: pItem.content,
                    imageData: pItem.imageData,
                    contentKind: parseContentKind(pItem.contentKind),
                    pasteboardSnapshot: pItem.pasteboardSnapshot,
                    sourceAppBundleID: pItem.sourceAppBundleID
                )
                item.state = parseItemState(pItem.state)
                items.append(item)
            }
            currentIndex = min(max(persisted.currentIndex, 0), max(0, items.count - 1))
            // If the persisted queue was fully consumed last time (no pending items),
            // start fresh rather than showing a wall of checkmarks with nothing actionable.
            if !items.isEmpty, items.allSatisfy({ $0.state == .done || $0.state == .skipped }) {
                items.removeAll()
                currentIndex = 0
                RelayQueuePersistence.delete()
            } else {
                markCurrentIfNeeded()
            }
        }

        clipboardController?.pauseMonitoring(persistent: false)
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
        clipboardController?.resumeMonitoring(persistent: false)
    }

    func resume() {
        guard isActive, isPaused else { return }
        isPaused = false
        clipboardController?.pauseMonitoring(persistent: false)
        startMonitor()
        startHotkeys()
    }

    func deactivate(clearQueue: Bool = false) {
        lastRecirculation = nil
        lastRecirculationExpiry?.cancel()
        lastRecirculationExpiry = nil
        guard isActive else { return }
        isActive = false
        isPaused = false
        stopMonitor()
        stopHotkeys()
        dismissWindow()

        if clearQueue {
            RelayQueuePersistence.delete()
        } else {
            // Persist every item (including image/rich-text) so nothing is lost across restarts.
            let toSave = items.map { item in
                PersistedRelayItem(
                    id: item.id,
                    content: item.content,
                    imageData: item.imageData,
                    contentKind: contentKindRawValue(item.contentKind),
                    pasteboardSnapshot: item.pasteboardSnapshot,
                    state: stateRawValue(item.state),
                    sourceAppBundleID: item.sourceAppBundleID
                )
            }
            let savedIndex = min(max(currentIndex, 0), max(0, items.count - 1))
            RelayQueuePersistence.save(toSave, currentIndex: savedIndex)
        }

        items.removeAll()
        currentIndex = 0
        clipboardController?.resumeMonitoring(persistent: false)
    }

    // MARK: - External API

    /// Tells the relay clipboard monitor to ignore the next pasteboard change.
    /// Called from external paste paths (e.g. quick panel) to prevent their
    /// clipboard writes from polluting the relay queue while relay is active.
    func skipMonitorNextChange() {
        guard isActive else { return }
        monitor?.skipNextChange()
    }

    // MARK: - Orchestration

    private func startMonitor() {
        let mon = RelayClipboardMonitor()
        mon.onNewClip = { [weak self] clip in
            self?.enqueue(clipItems: [clip])
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
        // Chain each paste request behind the previously-scheduled one. Swift
        // Tasks yield at `await` points, so without this chain multiple rapid
        // hotkey presses run concurrently and their pasteboard writes race —
        // see `currentPasteTask` for the full motivation.
        let previous = currentPasteTask
        currentPasteTask = Task { [weak self] in
            await previous?.value
            await self?.performOnePaste()
        }
    }

    @MainActor
    private func performOnePaste() async {
        guard let item = advance() else {
            handleQueueExhausted()
            return
        }
        guard let mon = monitor else { return }
        // Evaluate rule conditions against this specific item. Non-empty only when a
        // rule is selected AND its conditions match (content type / source app / etc.).
        // Re-routing rich-text items to the plain-text path so actions can transform
        // `item.content` — issue #22.
        let matchedActions = RelayRuleResolver.actionsApplying(to: item)

        // Plain-text override takes precedence — user explicitly chose string-only paste.
        if pasteAsPlainText || !matchedActions.isEmpty {
            await RelayPaster.paste(item.content, actions: matchedActions, monitor: mon)
        } else if let snapshot = item.pasteboardSnapshot {
            // Rich-text / native-fidelity path: replay the source's original pasteboard bytes.
            await RelayPaster.pasteSnapshot(snapshot, monitor: mon)
        } else {
            switch item.contentKind {
            case .image:
                if let imageData = item.imageBytesForExport() {
                    await RelayPaster.pasteImage(imageData, monitor: mon)
                } else {
                    await RelayPaster.paste(item.content, monitor: mon)
                }
            case .file:
                await RelayPaster.pasteFile(item.content, imageData: item.imageBytesForExport(), monitor: mon)
            case .text:
                await RelayPaster.paste(item.content, monitor: mon)
            }
        }
        SoundManager.playPaste()
        if isQueueExhausted {
            handleQueueExhausted()
        }
    }

    private func handleQueueExhausted() {
        SoundManager.playRelayComplete()
        if loopEnabled {
            restartQueue()
            return
        }
        if autoExitOnEmpty {
            deactivate(clearQueue: true)
        }
    }

    private func restartQueue() {
        guard !items.isEmpty else { return }
        for i in items.indices { items[i].state = .pending }
        currentIndex = 0
        items[0].state = .current
    }

    // MARK: - Private

    private func scheduleRecirculationExpiry(_ handle: RelayRecirculation.UndoHandle) {
        lastRecirculation = handle
        lastRecirculationExpiry?.cancel()
        lastRecirculationExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self else { return }
            if self.lastRecirculation?.relayItem.id == handle.relayItem.id {
                self.lastRecirculation = nil
            }
        }
    }

    func undoLastRecirculation() {
        guard let handle = lastRecirculation else { return }
        let target = min(handle.originalIndex, items.count)
        items.insert(handle.relayItem, at: target)
        if target <= currentIndex {
            currentIndex += 1
        }
        markCurrentIfNeeded()
        windowController?.updateSize(for: items.count)

        let context = ModelContext(PasteMemoApp.sharedModelContainer)
        RelayRecirculation.undoClipInsertion(handle, context: context)
        try? context.save()

        lastRecirculation = nil
        lastRecirculationExpiry?.cancel()
    }

    private func markCurrentIfNeeded() {
        guard !items.isEmpty else { return }
        guard items.first(where: { $0.state == .current }) == nil else { return }
        if let idx = items.firstIndex(where: { $0.state == .pending }) {
            items[idx].state = .current
            currentIndex = idx
        }
    }

    private func stateRawValue(_ state: RelayItem.ItemState) -> String {
        switch state {
        case .pending: return "pending"
        case .current: return "current"
        case .done: return "done"
        case .skipped: return "skipped"
        }
    }

    private func parseItemState(_ raw: String) -> RelayItem.ItemState {
        switch raw {
        case "current": return .current
        case "done": return .done
        case "skipped": return .skipped
        default: return .pending
        }
    }

    private func contentKindRawValue(_ kind: RelayItem.ContentKind) -> String {
        switch kind {
        case .text: return "text"
        case .image: return "image"
        case .file: return "file"
        }
    }

    private func parseContentKind(_ raw: String?) -> RelayItem.ContentKind {
        switch raw {
        case "image": return .image
        case "file": return .file
        default: return .text
        }
    }
}
