import Foundation
import SwiftData
import UserNotifications

enum AutomationResult: Sendable {
    case unchanged
    case applied(content: String, ruleName: String, actions: [RuleAction])
    case pendingConfirmation(content: String, ruleName: String, ruleID: String, actions: [RuleAction])
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
        context: ModelContext
    ) -> AutomationResult {
        guard ProManager.AUTOMATION_ENABLED else { return .unchanged }
        guard UserDefaults.standard.bool(forKey: "automationEnabled") else { return .unchanged }

        let rules = fetchEnabledRules(triggerMode: .automatic, context: context)

        var currentContent = content
        var allActions: [RuleAction] = []
        var lastRuleName = ""
        var needsConfirmation: (ruleName: String, ruleID: String)?

        for rule in rules {
            let conditions = rule.conditions
            let actions = rule.actions
            guard !conditions.isEmpty, !actions.isEmpty else { continue }
            guard Self.matchesConditions(
                conditions, logic: rule.conditionLogic, content: currentContent, contentType: contentType, sourceApp: sourceApp
            ) else { continue }

            let processed = Self.executeActions(actions, on: currentContent)
            let hasSpecialActions = Self.containsSpecialAction(actions)
            guard processed != currentContent || hasSpecialActions else { continue }

            currentContent = processed
            allActions.append(contentsOf: actions)
            lastRuleName = rule.name

            if rule.notifyOnTrigger {
                let displayName = rule.isBuiltIn ? L10n.tr(rule.name) : rule.name
                sendNotification(ruleName: displayName, content: processed)
            }

            if rule.notifyBeforeApply, needsConfirmation == nil {
                needsConfirmation = (ruleName: rule.name, ruleID: rule.ruleID)
            }
        }

        guard !allActions.isEmpty else { return .unchanged }

        if let confirm = needsConfirmation {
            return .pendingConfirmation(content: currentContent, ruleName: confirm.ruleName, ruleID: confirm.ruleID, actions: allActions)
        }
        return .applied(content: currentContent, ruleName: lastRuleName, actions: allActions)
    }

    /// Apply a single action to content. Used by command palette / context menu.
    func applyAction(_ action: RuleAction, to content: String) -> String {
        action.execute(on: content)
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
        switch logic {
        case .all:
            for condition in conditions {
                if !condition.matches(content: content, contentType: contentType, sourceApp: sourceApp) {
                    return false
                }
            }
            return true
        case .any:
            for condition in conditions {
                if condition.matches(content: content, contentType: contentType, sourceApp: sourceApp) {
                    return true
                }
            }
            return false
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

    nonisolated static func containsSpecialAction(_ actions: [RuleAction]) -> Bool {
        for action in actions {
            switch action {
            case .stripRichText, .assignGroup, .markSensitive, .pin, .skipCapture: return true
            default: break
            }
        }
        return false
    }

    nonisolated static func executeActions(_ actions: [RuleAction], on content: String) -> String {
        var current = content
        for action in actions {
            current = action.execute(on: current)
        }
        return current
    }

    // MARK: - Private

    private func sendNotification(ruleName: String, content: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let body = content.count > 80 ? String(content.prefix(80)) + "…" : content
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
