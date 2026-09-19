import Foundation
import SwiftData

@MainActor
enum RelayRuleResolver {

    static let ruleIdKey = "relayAutomationRuleId"

    /// Returns the currently selected automation rule, or nil.
    /// Returns nil if: no selection, rule not found, or rule disabled.
    static func currentRule() -> AutomationRule? {
        let raw = UserDefaults.standard.string(forKey: ruleIdKey) ?? ""
        guard !raw.isEmpty else { return nil }
        let context = ModelContext(PasteMemoApp.sharedModelContainer)
        let descriptor = FetchDescriptor<AutomationRule>(
            predicate: #Predicate { $0.ruleID == raw && $0.enabled == true }
        )
        return try? context.fetch(descriptor).first
    }

    /// Returns the actions of the currently selected rule, only when its conditions
    /// match the given relay item. Returns empty when no rule is selected, the rule
    /// is disabled, or its conditions don't match — callers can then fall through to
    /// the default non-rule paste path.
    static func actionsApplying(to item: RelayItem) -> [RuleAction] {
        guard let rule = currentRule() else { return [] }
        guard item.contentKind == .text else { return [] }
        let contentType = ClipboardManager.shared.detectContentType(item.content).type
        let ok = rule.conditions.isEmpty || AutomationEngine.matchesConditions(
            rule.conditions,
            logic: rule.conditionLogic,
            content: item.content,
            contentType: contentType,
            sourceApp: item.sourceAppBundleID
        )
        // Relay transforms text at paste time, synchronously: only content transforms
        // apply here. Async actions (Shortcuts) and metadata / flow actions would be
        // silent no-ops and are dropped.
        return ok ? rule.actions.filter { $0.kind == .transform } : []
    }

    /// Rules the Relay picker offers: enabled ones that are purely synchronous.
    static func isEligible(_ rule: AutomationRule) -> Bool {
        !rule.actions.contains(where: \.isAsync)
    }
}
