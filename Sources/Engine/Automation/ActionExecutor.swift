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
    /// Injectable for tests. `nil` = build from `AIProviderSettings` at call time.
    static var aiClientOverride: AIClient?
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
        guard !actions.isEmpty, !items.isEmpty else { return }

        // Async path (Shortcuts / AI): one clip, awaited in a task that outlives the
        // panel — closing it mid-request must not drop the result.
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
            finish(processed, for: item, rule: rule, actions: actions, context: context, outcome: &outcome)
        }
        conclude(outcome, rule: rule, actions: actions, host: host, context: context)
    }

    // MARK: - Async (Shortcuts / AI)

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

        if hasAI {
            guard aiClientOverride != nil || AIProviderSettings.isConfigured else {
                toast(L10n.tr("automation.ai.notConfigured"), icon: .info)
                return
            }
            do {
                try AITransformGuard.check(
                    content: item.content, isSensitive: item.isSensitive,
                    sourceAppBundleID: item.sourceAppBundleID,
                    blockedBundleIDs: MCPSourceAppBlocklist.shared.blockedBundleIDs
                )
            } catch let error as AIError {
                toast(error.userMessage, icon: .info)
                return
            } catch {
                toast(error.localizedDescription, icon: .info)
                return
            }
            let displayName = rule.isBuiltIn ? L10n.tr(rule.name) : rule.name
            toast(L10n.tr("automation.ai.processing", displayName), icon: .info, sticky: true)
        }

        var current = item.content
        // Verbatim original (not the thumbnail) — a Shortcut may save/process the image.
        let imageData = hasShortcut ? item.imageBytesForExport() : nil
        let contentType = item.contentType

        for action in actions {
            switch action {
            case .aiTransform(let prompt, let thinking, let temperature, let timeout):
                guard contentType.isMergeable else { continue }
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
                if action.kind == .transform, contentType.isMergeable {
                    current = action.execute(on: current)
                }
            }
        }

        if hasShortcut {
            // The Shortcut owns its output (Copy to Clipboard, webhook, …); the rule's
            // output mode doesn't apply. Same contract as before.
            if showsToast { ToastCenter.shared.dismiss() }
            let displayName = rule.isBuiltIn ? L10n.tr(rule.name) : rule.name
            ShortcutNotifier.showSuccess(ruleName: displayName)
            return
        }

        // The clip may have been deleted while the request was running.
        guard !item.isDeleted, item.modelContext != nil else {
            if showsToast { ToastCenter.shared.dismiss() }
            return
        }
        var outcome = Outcome()
        finish(current, for: item, rule: rule, actions: actions, context: context, outcome: &outcome)
        if showsToast { ToastCenter.shared.dismiss() }
        if hasAI, outcome.appliedCount == 0 {
            // The model handed the text back as it was: say so instead of going quiet.
            toast(L10n.tr("automation.ai.noChange"), icon: .info)
            return
        }
        conclude(outcome, rule: rule, actions: actions, host: host, context: context)
    }

    // MARK: - Shared tail

    private struct Outcome {
        var appliedCount = 0
        var pendingPaste: [String] = []
    }

    /// Route one clip's processed text by output mode and apply metadata.
    private static func finish(
        _ processed: String, for item: ClipItem, rule: AutomationRule, actions: [RuleAction],
        context: ModelContext, outcome: inout Outcome
    ) {
        let contentChanged = processed != item.content
        guard contentChanged || AutomationEngine.containsSpecialAction(actions) else { return }
        outcome.appliedCount += 1
        let target = deliver(processed, contentChanged: contentChanged, from: item,
                             mode: rule.outputMode, actions: actions, context: context)
        if rule.outputMode == .pasteToFrontmost { outcome.pendingPaste.append(processed) }
        applyMetadata(actions, to: target, context: context)
    }

    private static func conclude(_ outcome: Outcome, rule: AutomationRule, actions: [RuleAction], host: ActionHost, context: ModelContext) {
        ClipItemStore.saveAndNotify(context)
        guard outcome.appliedCount > 0 else { return }
        if actions.contains(.closeQuickPanel) || rule.outputMode == .pasteToFrontmost {
            host.dismissPanel()
        }
        if !outcome.pendingPaste.isEmpty {
            let text = outcome.pendingPaste.joined(separator: "\n")
            if let target = host.targetApp {
                // Same order as the panel's other paste commands: panel down,
                // target back in front, then ⌘V posted straight to its pid.
                target.activate()
                ClipboardManager.shared.pasteAsPlainText(text, targetApp: target)
                return
            }
            // No paste target (main window): fall back to the clipboard, like every
            // other paste-flavoured command does there.
            ClipboardManager.shared.writePlainText(text)
            toast(L10n.tr("action.copied"))
            return
        }
        toast(L10n.tr("automation.applied"))
    }

    /// Route the processed text according to the rule's output mode. Returns the
    /// clip that metadata actions should land on (the new clip for `.newItem`
    /// when a new clip was created, the original otherwise).
    private static func deliver(
        _ processed: String,
        contentChanged: Bool,
        from item: ClipItem,
        mode: RuleOutputMode,
        actions: [RuleAction],
        context: ModelContext
    ) -> ClipItem {
        switch mode {
        case .replaceItem:
            rewrite(item, with: processed, contentChanged: contentChanged, actions: actions)
            return item

        case .newItem:
            guard contentChanged else { return item }
            let newItem = ClipItem(
                content: processed,
                contentType: item.contentType,
                sourceApp: item.sourceApp,
                sourceAppBundleID: item.sourceAppBundleID
            )
            newItem.displayTitle = ClipItem.buildTitle(content: processed, contentType: item.contentType)
            context.insert(newItem)
            return newItem

        case .clipboard:
            ClipboardManager.shared.writePlainText(processed)
            return item

        case .pasteToFrontmost:
            // Pasted once, after the loop, so multi-select pastes one joined block.
            return item
        }
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
