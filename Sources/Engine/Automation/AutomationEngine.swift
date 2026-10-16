import Foundation
import SwiftData
import UserNotifications

enum AutomationResult: Sendable {
    case unchanged
    case applied(content: String, ruleName: String, actions: [RuleAction], writeBack: Bool, outputs: [CaptureOutput])
    case pendingConfirmation(content: String, ruleName: String, ruleID: String, actions: [RuleAction], writeBack: Bool, outputs: [CaptureOutput])
}

@MainActor
final class AutomationEngine {
    static let shared = AutomationEngine()

    private init() {}

    // MARK: - Public API

    /// Process content through enabled automatic rules. Called during clipboard capture.
    /// All matching rules are executed in order, with results accumulated.
    func process(
        content: String,
        contentType: ClipContentType,
        sourceApp: String?,
        isSensitive: Bool = false,
        context: ModelContext
    ) -> AutomationResult {
        guard ProManager.AUTOMATION_ENABLED else { return .unchanged }
        guard UserDefaults.standard.bool(forKey: "automationEnabled") else { return .unchanged }

        let rules = fetchEnabledRules(triggerMode: .automatic, context: context)

        var currentContent = content
        var allActions: [RuleAction] = []
        var lastRuleName = ""
        var writeBack = false
        var outputs: [CaptureOutput] = []
        var matchedAny = false
        var needsConfirmation: (ruleName: String, ruleID: String)?
        // The new clip's state as earlier rules in this pass leave it, so a later
        // rule's "is pinned" / "in group" sees the pin / group an earlier one set.
        var input = ConditionInput(content: content, contentType: contentType, sourceApp: sourceApp, isSensitive: isSensitive)

        for rule in rules {
            let conditions = rule.conditions
            let actions = rule.actions
            let hasOutput = rule.outputMode.needsParameter
            guard !conditions.isEmpty, !actions.isEmpty || hasOutput else { continue }
            input.content = currentContent
            guard Self.matchesConditions(conditions, logic: rule.conditionLogic, input: input) else { continue }

            let processed = Self.executeActions(actions, on: currentContent)
            let hasSpecialActions = Self.containsSpecialAction(actions)
            guard processed != currentContent || hasSpecialActions || hasOutput else { continue }

            matchedAny = true
            currentContent = processed
            allActions.append(contentsOf: actions)
            for action in actions {
                switch action {
                case .pin: input.isPinned = true
                case .unpin: input.isPinned = false
                case .markSensitive: input.isSensitive = true
                case .unmarkSensitive: input.isSensitive = false
                case .assignGroup(let name) where !name.isEmpty: input.groupName = name
                default: break
                }
            }
            lastRuleName = rule.name
            if rule.outputMode.mirrorsToPasteboardOnCapture { writeBack = true }
            if hasOutput {
                let displayName = rule.isBuiltIn ? L10n.tr(rule.name) : rule.name
                outputs.append(CaptureOutput(mode: rule.outputMode, param: rule.outputParam, ruleName: displayName))
            }

            if rule.notifyOnTrigger {
                let displayName = rule.isBuiltIn ? L10n.tr(rule.name) : rule.name
                sendNotification(ruleName: displayName, content: processed, contentType: contentType)
            }

            if rule.notifyBeforeApply, needsConfirmation == nil {
                needsConfirmation = (ruleName: rule.name, ruleID: rule.ruleID)
            }

            // Short-circuit: later rules don't get to rewrite this rule's result.
            if actions.contains(.stopProcessing) { break }
        }

        guard matchedAny else { return .unchanged }

        if let confirm = needsConfirmation {
            return .pendingConfirmation(content: currentContent, ruleName: confirm.ruleName, ruleID: confirm.ruleID, actions: allActions, writeBack: writeBack, outputs: outputs)
        }
        return .applied(content: currentContent, ruleName: lastRuleName, actions: allActions, writeBack: writeBack, outputs: outputs)
    }

    /// Apply a sequence of actions to content. Pure text transformation, no SwiftData needed.
    /// Used by Relay mode to transform queue items at paste time / for preview.
    nonisolated static func apply(_ actions: [RuleAction], to content: String) -> String {
        actions.reduce(content) { $1.execute(on: $0) }
    }

    // MARK: - Static Helpers (testable without ModelContext)

    nonisolated static func matchesConditions(
        _ conditions: [RuleCondition],
        logic: ConditionLogic = .all,
        content: String,
        contentType: ClipContentType,
        sourceApp: String?
    ) -> Bool {
        matchesConditions(conditions, logic: logic,
                          input: ConditionInput(content: content, contentType: contentType, sourceApp: sourceApp))
    }

    nonisolated static func matchesConditions(
        _ conditions: [RuleCondition],
        logic: ConditionLogic = .all,
        input: ConditionInput
    ) -> Bool {
        switch logic {
        case .all: return conditions.allSatisfy { $0.matches(input) }
        case .any: return conditions.contains { $0.matches(input) }
        }
    }

    /// Backward-compatible alias
    nonisolated static func matchesAllConditions(
        _ conditions: [RuleCondition],
        content: String,
        contentType: ClipContentType,
        sourceApp: String?
    ) -> Bool {
        matchesConditions(conditions, logic: .all, content: content, contentType: contentType, sourceApp: sourceApp)
    }

    /// Anything that isn't a pure text transform counts: such a rule "applies" even
    /// when the text comes out unchanged.
    nonisolated static func containsSpecialAction(_ actions: [RuleAction]) -> Bool {
        actions.contains { $0.kind == .metadata || $0.kind == .sideEffect }
    }

    nonisolated static func executeActions(_ actions: [RuleAction], on content: String) -> String {
        var current = content
        for action in actions {
            current = action.execute(on: current)
        }
        return current
    }

    // MARK: - Private

    private func sendNotification(ruleName: String, content: String, contentType: ClipContentType) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        // Text clips show a content preview; image/file/etc. clips show their type
        // name instead of the raw "[Image]" placeholder or a file path. (issue #71)
        let body: String
        if contentType.isMergeable {
            body = content.count > 80 ? String(content.prefix(80)) + "…" : content
        } else {
            body = contentType.label
        }
        let notifContent = UNMutableNotificationContent()
        notifContent.title = L10n.tr("automation.notification.title") + ": " + ruleName
        notifContent.body = body
        notifContent.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: notifContent, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func fetchEnabledRules(triggerMode: TriggerMode, context: ModelContext) -> [AutomationRule] {
        let descriptor = FetchDescriptor<AutomationRule>(
            predicate: #Predicate { $0.enabled },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let rules = (try? context.fetch(descriptor)) ?? []
        return rules.filter { $0.triggerMode == triggerMode }
    }
}
