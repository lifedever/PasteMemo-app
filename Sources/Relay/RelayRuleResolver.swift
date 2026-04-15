import Foundation
import SwiftData

@MainActor
enum RelayRuleResolver {

    static let ruleIdKey = "relayAutomationRuleId"

    /// Returns the actions of the currently selected automation rule, or empty array.
    /// Returns empty if: no selection, rule not found, or rule disabled.
    static func currentRuleActions() -> [RuleAction] {
        let raw = UserDefaults.standard.string(forKey: ruleIdKey) ?? ""
        guard !raw.isEmpty else { return [] }
        let context = ModelContext(PasteMemoApp.sharedModelContainer)
        let descriptor = FetchDescriptor<AutomationRule>(
            predicate: #Predicate { $0.ruleID == raw && $0.enabled == true }
        )
        if let rule = try? context.fetch(descriptor).first {
            return rule.actions
        }
        return []
    }
}
