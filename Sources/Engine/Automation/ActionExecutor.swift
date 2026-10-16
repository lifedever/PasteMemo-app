import AppKit
import Foundation
import SwiftData

/// Which path is running a rule. The executor uses it to decide what an output
/// mode means (there's no paste target on capture, no panel in the main window).
enum ExecutionSource: Sendable {
    case capture
    case quickPanel
    case mainWindow
    case relay
}

/// The runtime environment a rule runs in. Views / window controllers adopt it;
/// the executor never imports them, so it stays testable from Engine.
@MainActor
protocol ActionHost: AnyObject {
    var source: ExecutionSource { get }
    /// App to paste into for `.pasteToFrontmost` (the app that was frontmost
    /// before the Quick Panel opened). `nil` in the main window.
    var targetApp: NSRunningApplication? { get }
    /// Tear down the Quick Panel. No-op for hosts without one.
    func dismissPanel()
}

/// Host for callers without a panel (main window, tests).
@MainActor
final class PlainActionHost: ActionHost {
    let source: ExecutionSource
    let targetApp: NSRunningApplication?
    init(source: ExecutionSource, targetApp: NSRunningApplication? = nil) {
        self.source = source
        self.targetApp = targetApp
    }
    func dismissPanel() {}
}

/// The one place a rule is applied to clips outside the capture path. Merges
/// what used to be `QuickPanelView.applyRule`, `MainWindowView.applyAutomationRule`
/// and their two copies of `runRuleViaShortcut`; the capture path shares the
/// metadata step (`applyMetadata`).
@MainActor
enum ActionExecutor {

    /// Tests run without a window server; they turn the toast off.
    static var showsToast = true
    /// Tests run without a window server or browser; they turn side effects that
    /// open windows / touch the Relay queue off and read them from `lastSideEffects`.
    static var performsSideEffects = true
    private(set) static var lastSideEffects = SideEffects()
    /// Injectable for tests. `nil` = build from `AIProviderSettings` at call time.
    static var aiClientOverride: AIClient?
    /// Injectable for tests. `nil` = cached OCR text, else recognise on demand.
    static var ocrOverride: (@MainActor (ClipItem) async -> String?)?
    /// Clips with an AI request in flight — a second ⌘K on the same clip is refused
    /// instead of firing a second request.
    private(set) static var inFlightItemIDs: Set<String> = []

    private static func toast(_ message: String, icon: ToastIcon = .success, sticky: Bool = false) {
        guard showsToast else { return }
        ToastCenter.shared.show(ToastDescriptor(message: message, icon: icon, duration: sticky ? nil : 1.5))
    }

    // MARK: - Manual apply (⌘K / context menu)

    static func apply(
        _ rule: AutomationRule,
        to items: [ClipItem],
        host: ActionHost,
        context: ModelContext
    ) {
        let actions = rule.actions
        guard !actions.isEmpty || rule.outputMode.needsParameter, !items.isEmpty else { return }

        // Async path (Shortcuts / AI / OCR): one clip, awaited in a task that outlives
        // the panel — closing it mid-request must not drop the result.
        if actions.contains(where: \.isAsync), let item = items.first {
            Task { @MainActor in
                await applyAsync(rule, to: item, host: host, context: context)
            }
            return
        }

        let transforms = actions.filter { $0.kind == .transform }
        var outcome = Outcome()

        ClipItemStore.isBulkOperation = items.count > 1
        defer { ClipItemStore.isBulkOperation = false }

        for item in items {
            // Text transforms only make sense on text-like clips; images / files
            // still receive metadata actions. (issue #71)
            let processed = item.contentType.isMergeable
                ? AutomationEngine.executeActions(transforms, on: item.content)
                : item.content
            finish(processed, for: item, producedText: false, rule: rule, actions: actions, context: context, outcome: &outcome)
        }
        conclude(outcome, rule: rule, actions: actions, host: host, context: context)
    }

    // MARK: - Async (Shortcuts / AI / OCR)

    private static func applyAsync(_ rule: AutomationRule, to item: ClipItem, host: ActionHost, context: ModelContext) async {
        let actions = rule.actions
        let itemID = item.itemID
        guard !inFlightItemIDs.contains(itemID) else {
            toast(L10n.tr("automation.ai.busy"), icon: .info)
            return
        }
        inFlightItemIDs.insert(itemID)
        defer { inFlightItemIDs.remove(itemID) }

        let hasAI = actions.contains { if case .aiTransform = $0 { return true }; return false }
        let hasShortcut = actions.contains { if case .runShortcut = $0 { return true }; return false }
        let displayName = rule.isBuiltIn ? L10n.tr(rule.name) : rule.name

        if hasAI, aiClientOverride == nil, !AIProviderSettings.isConfigured {
            toast(L10n.tr("automation.ai.notConfigured"), icon: .info)
            return
        }

        var current = item.content
        // Verbatim original (not the thumbnail) — a Shortcut may save/process the image.
        let imageData = hasShortcut ? item.imageBytesForExport() : nil
        let contentType = item.contentType
        // An image clip turns into text once OCR ran; later actions see that text.
        var hasText = contentType.isMergeable
        var producedText = false
        var showedAIToast = false

        for action in actions {
            switch action {
            case .runOCR:
                guard contentType == .image, !producedText else { continue }
                let recognized = await recognizedText(for: item)
                guard let recognized, !recognized.isEmpty else {
                    if showsToast { ToastCenter.shared.dismiss() }
                    toast(L10n.tr("detail.ocr.empty"), icon: .info)
                    return
                }
                current = recognized
                hasText = true
                producedText = true
            case .aiTransform(let prompt, let thinking, let temperature, let timeout):
                guard hasText else { continue }
                do {
                    // Checked against the text actually sent — after OCR that's the
                    // recognised text, not the image placeholder.
                    try AITransformGuard.check(
                        content: current, isSensitive: item.isSensitive,
                        sourceAppBundleID: item.sourceAppBundleID,
                        blockedBundleIDs: MCPSourceAppBlocklist.shared.blockedBundleIDs
                    )
                } catch let error as AIError {
                    if showsToast { ToastCenter.shared.dismiss() }
                    toast(error.userMessage, icon: .info)
                    return
                } catch {
                    if showsToast { ToastCenter.shared.dismiss() }
                    toast(error.localizedDescription, icon: .info)
                    return
                }
                if !showedAIToast {
                    toast(L10n.tr("automation.ai.processing", displayName), icon: .info, sticky: true)
                    showedAIToast = true
                }
                do {
                    if aiClientOverride == nil, AIProviderSettings.mode == .local {
                        // A CLI takes no thinking/temperature knobs — it was configured
                        // once, in its own settings, and reads none of ours.
                        var cli = AIProviderSettings.cliSnapshot()
                        if let timeout { cli.timeout = timeout }
                        current = try await AICLIBackend(config: cli).transform(prompt: prompt, content: current)
                    } else {
                        var config = aiClientOverride?.config ?? AIProviderSettings.snapshot()
                        if let thinking { config.thinking = thinking }
                        if let temperature { config.temperature = temperature }
                        if let timeout { config.timeout = timeout }
                        let client = aiClientOverride.map { AIClient(config: config, transport: $0.transport) }
                            ?? AIClient(config: config)
                        current = try await client.transform(prompt: prompt, content: current)
                    }
                } catch {
                    if showsToast { ToastCenter.shared.dismiss() }
                    toast((error as? AIError)?.userMessage ?? error.localizedDescription, icon: .info)
                    return
                }
            case .runShortcut(let name):
                do {
                    _ = try await ShortcutRunner.run(
                        name: name, content: current, imageData: imageData, contentType: contentType
                    )
                } catch {
                    if showsToast { ToastCenter.shared.dismiss() }
                    ShortcutNotifier.showFailure(ruleName: name, error: error)
                    return
                }
            default:
                if action.kind == .transform, hasText {
                    current = action.execute(on: current)
                }
            }
        }

        if hasShortcut {
            // The Shortcut owns its output (Copy to Clipboard, webhook, …); the rule's
            // output mode doesn't apply. Same contract as before.
            if showsToast { ToastCenter.shared.dismiss() }
            ShortcutNotifier.showSuccess(ruleName: displayName)
            return
        }

        // The clip may have been deleted while the request was running.
        guard !item.isDeleted, item.modelContext != nil else {
            if showsToast { ToastCenter.shared.dismiss() }
            return
        }
        var outcome = Outcome()
        finish(current, for: item, producedText: producedText, rule: rule, actions: actions, context: context, outcome: &outcome)
        if showsToast { ToastCenter.shared.dismiss() }
        if hasAI, outcome.appliedCount == 0 {
            // The model handed the text back as it was: say so instead of going quiet.
            toast(L10n.tr("automation.ai.noChange"), icon: .info)
            return
        }
        conclude(outcome, rule: rule, actions: actions, host: host, context: context)
    }

    // MARK: - Shared tail

    /// What a run's side-effect actions asked for, collected per clip and carried
    /// out once in `conclude`. Also what tests read back.
    struct SideEffects: Equatable {
        var links: [URL] = []
        var finderPaths: [String] = []
        var previewItemID: String?
        var relayTexts: [String] = []
        var relayItemIDs: [String] = []
        var deletedItemIDs: [String] = []
        var sound: String?
    }

    private struct Outcome {
        var appliedCount = 0
        var pendingPaste: [String] = []
        var savedFiles: [URL] = []
        var saveFailed = false
        var webhookPayloads: [RuleOutputDelivery.WebhookPayload] = []
        /// L10n key explaining why a clip wasn't sent (sensitive / not text).
        var webhookSkipReason: String?
        var effects = SideEffects()
        var previewItem: ClipItem?
        var relayItems: [ClipItem] = []
        var itemsToDelete: [ClipItem] = []
    }

    /// Opening more than this many links from one multi-select run is almost
    /// certainly a mistake; the rest are dropped.
    private static let MAX_LINKS_PER_RUN = 10

    /// Route one clip's processed text by output mode, apply metadata, collect
    /// side effects. `producedText` = the text came from OCR of a non-text clip.
    private static func finish(
        _ processed: String, for item: ClipItem, producedText: Bool, rule: AutomationRule,
        actions: [RuleAction], context: ModelContext, outcome: inout Outcome
    ) {
        let contentChanged = processed != item.content
        guard contentChanged || rule.outputMode.needsParameter
                || AutomationEngine.containsSpecialAction(actions) else { return }
        outcome.appliedCount += 1
        let target = deliver(processed, contentChanged: contentChanged, producedText: producedText,
                             from: item, rule: rule, actions: actions, context: context, outcome: &outcome)
        if rule.outputMode == .pasteToFrontmost { outcome.pendingPaste.append(processed) }
        applyMetadata(actions, to: target, context: context)
        collectSideEffects(actions, processed: processed, hasText: producedText || item.contentType.isMergeable,
                           item: item, outcome: &outcome)
    }

    private static func collectSideEffects(
        _ actions: [RuleAction], processed: String, hasText: Bool, item: ClipItem, outcome: inout Outcome
    ) {
        for action in actions {
            switch action {
            case .openLink:
                guard hasText, outcome.effects.links.count < MAX_LINKS_PER_RUN,
                      let url = linkToOpen(in: processed) else { continue }
                outcome.effects.links.append(url)
            case .openInPreview:
                guard outcome.previewItem == nil else { continue }
                outcome.previewItem = item
                outcome.effects.previewItemID = item.itemID
            case .showInFinder:
                guard let path = item.revealableFinderPath else { continue }
                outcome.effects.finderPaths.append(path)
            case .addToRelay:
                if hasText {
                    outcome.effects.relayTexts.append(processed)
                } else {
                    outcome.relayItems.append(item)
                    outcome.effects.relayItemIDs.append(item.itemID)
                }
            case .splitToRelay(let delimiter):
                guard hasText else { continue }
                outcome.effects.relayTexts.append(contentsOf: split(processed, by: delimiter))
            case .deleteItem:
                outcome.itemsToDelete.append(item)
                outcome.effects.deletedItemIDs.append(item.itemID)
            case .playSound(let name):
                if !name.isEmpty { outcome.effects.sound = name }
            default:
                continue
            }
        }
    }

    /// The result itself when it's an http(s) address, otherwise the first link found
    /// in it. Not `URL.fromLinkString`: that prefixes https:// onto any bare word, so a
    /// clip saying "hello" would open https://hello. Other schemes (file:, javascript:,
    /// app URLs) are never opened from a rule.
    static func linkToOpen(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           url.host?.isEmpty == false {
            return url
        }
        return TextEntityExtractor.linkURLs(in: text).first.flatMap(URL.init(string:))
    }

    /// Pieces for "split into Relay": empty delimiter = newline; blank pieces dropped.
    nonisolated static func split(_ text: String, by delimiter: String) -> [String] {
        let separator = delimiter.isEmpty ? "\n" : delimiter
        return text.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func conclude(_ outcome: Outcome, rule: AutomationRule, actions: [RuleAction], host: ActionHost, context: ModelContext) {
        ClipItemStore.saveAndNotify(context)
        lastSideEffects = outcome.effects
        guard outcome.appliedCount > 0 else { return }
        let leaves = !outcome.effects.links.isEmpty || !outcome.effects.finderPaths.isEmpty
        if actions.contains(.closeQuickPanel) || rule.outputMode == .pasteToFrontmost || leaves {
            host.dismissPanel()
        }
        var toastShown = false
        if !outcome.pendingPaste.isEmpty {
            let text = outcome.pendingPaste.joined(separator: "\n")
            if let target = host.targetApp {
                // Same order as the panel's other paste commands: panel down,
                // target back in front, then ⌘V posted straight to its pid.
                target.activate()
                ClipboardManager.shared.pasteAsPlainText(text, targetApp: target)
            } else {
                // No paste target (main window): fall back to the clipboard, like every
                // other paste-flavoured command does there.
                ClipboardManager.shared.writePlainText(text)
                toast(L10n.tr("action.copied"))
            }
            toastShown = true
        }
        performSideEffects(outcome, context: context)
        if !outcome.webhookPayloads.isEmpty {
            sendWebhooks(outcome.webhookPayloads, to: rule.outputParam)
            toastShown = true
        }
        // The delete brings its own undo toast; anything shown now would replace it.
        guard outcome.itemsToDelete.isEmpty, !toastShown else { return }
        if let reason = outcome.webhookSkipReason {
            toast(L10n.tr(reason), icon: .info)
        } else if outcome.saveFailed {
            toast(L10n.tr("automation.output.saveFailed"), icon: .info)
        } else if let saved = outcome.savedFiles.first {
            toast(L10n.tr("automation.output.saved", saved.deletingLastPathComponent().lastPathComponent))
        } else {
            toast(L10n.tr("automation.applied"))
        }
    }

    private static func performSideEffects(_ outcome: Outcome, context: ModelContext) {
        let effects = outcome.effects
        guard performsSideEffects else { return }
        if let sound = effects.sound { SoundManager.play(storageKey: sound) }
        for url in effects.links { NSWorkspace.shared.open(url) }
        if !effects.finderPaths.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(effects.finderPaths.map { URL(fileURLWithPath: $0) })
        }
        if let item = outcome.previewItem { QuickLookHelper.shared.present(item: item) }
        if !effects.relayTexts.isEmpty { RelayManager.shared.addToQueue(texts: effects.relayTexts) }
        if !outcome.relayItems.isEmpty { RelayManager.shared.addToQueue(clipItems: outcome.relayItems) }
        if !outcome.itemsToDelete.isEmpty {
            DeleteUndoCoordinator.shared.scheduleUndoableDelete(items: outcome.itemsToDelete, context: context)
        }
    }

    private static func sendWebhooks(_ payloads: [RuleOutputDelivery.WebhookPayload], to param: String) {
        Task { @MainActor in
            var failure: Error?
            for payload in payloads {
                do {
                    try await RuleOutputDelivery.post(payload, to: param)
                } catch {
                    failure = error
                }
            }
            if let failure {
                toast(RuleOutputDelivery.message(for: failure), icon: .info)
            } else {
                toast(L10n.tr("automation.output.webhook.sent"))
            }
        }
    }

    /// Route the processed text according to the rule's output mode. Returns the
    /// clip that metadata actions should land on (the new clip when one was
    /// created, the original otherwise).
    private static func deliver(
        _ processed: String,
        contentChanged: Bool,
        producedText: Bool,
        from item: ClipItem,
        rule: AutomationRule,
        actions: [RuleAction],
        context: ModelContext,
        outcome: inout Outcome
    ) -> ClipItem {
        let hasText = producedText || item.contentType.isMergeable
        switch rule.outputMode {
        case .replaceItem where producedText, .newItem:
            // An image can't be overwritten with its OCR text, so "replace" adds the
            // text as its own clip next to it.
            guard contentChanged else { return item }
            let type = producedText ? ClipboardManager.shared.detectContentType(processed).type : item.contentType
            let newItem = ClipItem(
                content: processed,
                contentType: type,
                sourceApp: item.sourceApp,
                sourceAppBundleID: item.sourceAppBundleID
            )
            newItem.displayTitle = ClipItem.buildTitle(content: processed, contentType: type)
            context.insert(newItem)
            return newItem

        case .replaceItem:
            rewrite(item, with: processed, contentChanged: contentChanged, actions: actions)
            return item

        case .clipboard:
            if hasText { ClipboardManager.shared.writePlainText(processed) }
            return item

        case .pasteToFrontmost:
            // Pasted once, after the loop, so multi-select pastes one joined block.
            return item

        case .saveToFile:
            if let folder = RuleOutputDelivery.folderURL(from: rule.outputParam),
               let url = RuleOutputDelivery.save(text: processed, of: item, asText: hasText, into: folder) {
                outcome.savedFiles.append(url)
            } else {
                outcome.saveFailed = true
            }
            return item

        case .postWebhook:
            guard hasText else {
                outcome.webhookSkipReason = "automation.output.webhook.textOnly"
                return item
            }
            guard RuleOutputDelivery.mayLeaveDevice(isSensitive: item.isSensitive, sourceAppBundleID: item.sourceAppBundleID) else {
                outcome.webhookSkipReason = "automation.output.webhook.refused"
                return item
            }
            let ruleName = rule.isBuiltIn ? L10n.tr(rule.name) : rule.name
            outcome.webhookPayloads.append(
                RuleOutputDelivery.payload(content: processed, item: item, ruleName: ruleName, asText: true)
            )
            return item
        }
    }

    /// Text recognised in an image clip: the cached OCR result, else run it now
    /// (with the usual progress toast when it takes a moment).
    private static func recognizedText(for item: ClipItem) async -> String? {
        if let ocrOverride { return await ocrOverride(item) }
        if let cached = item.ocrText, !cached.isEmpty { return cached }
        return await OCRTaskCoordinator.shared.recognizeOnDemandWithProgress(itemID: item.itemID)
    }

    private static func rewrite(_ item: ClipItem, with processed: String, contentChanged: Bool, actions: [RuleAction]) {
        guard item.contentType.isMergeable else { return }
        item.content = processed
        item.displayTitle = ClipItem.buildTitle(content: processed, contentType: item.contentType)
        // Stale rich text would otherwise show through in the preview pane even
        // though the plain content changed — and the copy-time pasteboard snapshot
        // would make ⌘V paste the *original* bytes (paste replays it verbatim).
        if contentChanged || actions.contains(.stripRichText) {
            item.richTextData = nil
            item.richTextType = nil
            item.pasteboardSnapshot = nil
        }
    }

    // MARK: - Metadata (shared with the capture path)

    /// pin / sensitive / group / strip-rich-text. Content-type agnostic — works on
    /// images and files too. Set-semantics only: `pin` pins, `unpin` unpins;
    /// toggling is the palette row's job, not the action's.
    static func applyMetadata(_ actions: [RuleAction], to item: ClipItem, context: ModelContext) {
        for action in actions {
            switch action {
            case .markSensitive: item.isSensitive = true
            case .unmarkSensitive: item.isSensitive = false
            case .pin: item.isPinned = true
            case .unpin: item.isPinned = false
            case .stripRichText:
                item.richTextData = nil
                item.richTextType = nil
            case .assignGroup(let name):
                guard !name.isEmpty else { continue }
                item.groupName = name
                ClipboardManager.shared.upsertSmartGroup(name: name, context: context)
            default:
                continue
            }
        }
    }

    /// Convenience for ⌘K rows that map straight onto a metadata action.
    static func applyMetadata(_ actions: [RuleAction], to items: [ClipItem], context: ModelContext) {
        for item in items {
            applyMetadata(actions, to: item, context: context)
        }
        ClipItemStore.saveAndNotify(context)
    }
}
