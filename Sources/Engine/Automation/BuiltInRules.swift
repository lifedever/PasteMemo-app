import Foundation
import SwiftData

enum BuiltInRules {
    private static let SEEDED_KEY = "builtInRulesSeeded_v2"

    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: SEEDED_KEY) else { return }

        // Remove old built-in rules before re-seeding
        let descriptor = FetchDescriptor<AutomationRule>(predicate: #Predicate { $0.isBuiltIn })
        if let oldRules = try? context.fetch(descriptor) {
            for rule in oldRules { context.delete(rule) }
        }

        for definition in definitions {
            let rule = AutomationRule(
                name: definition.name,
                enabled: definition.enabled,
                isBuiltIn: true,
                sortOrder: definition.sortOrder,
                triggerMode: .automatic,
                conditions: definition.conditions,
                actions: definition.actions
            )
            context.insert(rule)
        }

        try? context.save()
        UserDefaults.standard.set(true, forKey: SEEDED_KEY)

        if !UserDefaults.standard.bool(forKey: "automationEnabled") {
            UserDefaults.standard.set(true, forKey: "automationEnabled")
        }
    }

    private struct RuleDefinition {
        let name: String
        let enabled: Bool
        let sortOrder: Int
        let conditions: [RuleCondition]
        let actions: [RuleAction]
    }

    private static let definitions: [RuleDefinition] = [
        RuleDefinition(
            name: "automation.builtIn.cleanTracking",
            enabled: true,
            sortOrder: 0,
            conditions: [.contentType(.link)],
            actions: [.removeQueryParams(patterns: [
                "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term",
                "fbclid", "gclid", "mc_cid", "mc_eid",
            ])]
        ),
        RuleDefinition(
            name: "automation.builtIn.lowercaseEmail",
            enabled: true,
            sortOrder: 1,
            conditions: [.regexMatch(pattern: "^[\\w.+-]+@[\\w.-]+\\.[a-zA-Z]{2,}$")],
            actions: [.lowercased]
        ),
        RuleDefinition(
            name: "automation.builtIn.removeBlankLines",
            enabled: false,
            sortOrder: 2,
            conditions: [.contentType(.text)],
            actions: [.removeBlankLines]
        ),
    ]
}
