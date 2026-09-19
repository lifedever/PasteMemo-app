import Foundation
import SwiftData

enum BuiltInRules {
    private static let SEEDED_KEY = "builtInRulesSeeded_v2"
    /// Names of built-ins the user deleted. `seedMissing` skips these so a deleted
    /// rule doesn't come back at the next launch; "恢复内置规则" clears the list.
    private static let DELETED_KEY = "builtInRulesDeleted"

    static var deletedNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: DELETED_KEY) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: DELETED_KEY) }
    }

    /// Built-ins that shipped in an earlier build and were replaced. Removed on launch
    /// if still present and untouched (still `isBuiltIn`).
    private static let retiredNames: Set<String> = [
        "automation.builtIn.aiTranslateEn", "automation.builtIn.aiTranslateZh", "automation.builtIn.aiPolish",
    ]

    /// Earlier prompts of built-ins we've since reworded. A rule still carrying one of
    /// these verbatim (the user never touched it) is refreshed to the current definition.
    private static let supersededActions: [String: [[RuleAction]]] = [
        "automation.builtIn.aiTranslate": [
            [.aiTransform(prompt: "If the text is mainly Chinese, translate it into natural, fluent English; otherwise translate it into natural Simplified Chinese. Keep names, code, URLs and formatting as they are.")],
        ],
        "automation.builtIn.aiTidy": [
            [.aiTransform(prompt: "Tidy up this messy text (for example OCR output): fix broken line breaks, spacing and obvious recognition errors, restore paragraphs and lists. Keep the original language and every piece of information; do not summarise, add or drop anything.")],
            [.aiTransform(prompt: "Reformat this messy text (for example OCR output or a voice transcript) into clean, well-structured plain text. Restore paragraphs and sentence punctuation; when the text enumerates items or steps, lay them out as a numbered or bulleted list, one item per line; fix broken line breaks, spacing and obvious recognition errors. Keep the original language and every piece of information; do not summarise, add or drop anything, and do not use Markdown symbols like # or **.")],
        ],
    ]

    static func markDeleted(_ name: String) {
        var names = deletedNames
        names.insert(name)
        deletedNames = names
    }

    /// Bring back every deleted built-in (keeps the ones still present untouched).
    @MainActor
    static func restoreDeleted(context: ModelContext) {
        deletedNames = []
        seedMissing(context: context)
    }

    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: SEEDED_KEY) else {
            seedMissing(context: context)
            return
        }

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
                triggerMode: definition.triggerMode,
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

    /// Built-ins added after the one-time seed. Matched by name (built-in names are
    /// L10n keys, so they're stable) and inserted only when absent — bumping
    /// `SEEDED_KEY` instead would wipe the user's on/off choices for every built-in.
    @MainActor
    private static func seedMissing(context: ModelContext) {
        let descriptor = FetchDescriptor<AutomationRule>(predicate: #Predicate { $0.isBuiltIn })
        let builtIns = (try? context.fetch(descriptor)) ?? []
        var inserted = false
        for rule in builtIns where retiredNames.contains(rule.name) {
            context.delete(rule)
            inserted = true
        }
        for rule in builtIns {
            guard let old = supersededActions[rule.name], old.contains(rule.actions),
                  let current = definitions.first(where: { $0.name == rule.name }) else { continue }
            rule.actions = current.actions
            inserted = true
        }
        let existing = Set(builtIns.map(\.name))
        let deleted = deletedNames
        for definition in definitions where !existing.contains(definition.name) && !deleted.contains(definition.name) {
            let rule = AutomationRule(
                name: definition.name,
                enabled: definition.enabled,
                isBuiltIn: true,
                sortOrder: definition.sortOrder,
                triggerMode: definition.triggerMode,
                conditions: definition.conditions,
                actions: definition.actions
            )
            context.insert(rule)
            inserted = true
        }
        if inserted { try? context.save() }
    }

    private struct RuleDefinition {
        let name: String
        let enabled: Bool
        let sortOrder: Int
        var triggerMode: TriggerMode = .automatic
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
        // AI presets: manual-only by construction (aiTransform is async + network),
        // off until the user configures a provider and switches them on.
        RuleDefinition(
            name: "automation.builtIn.aiTranslate",
            enabled: false,
            sortOrder: 100,
            triggerMode: .manual,
            conditions: [.anyText],
            actions: [.aiTransform(prompt: "如果文本主要是中文，翻译成自然流畅的英文；否则翻译成自然的简体中文。人名、代码、链接和排版保持原样。")]
        ),
        RuleDefinition(
            name: "automation.builtIn.aiTidy",
            enabled: false,
            sortOrder: 101,
            triggerMode: .manual,
            conditions: [.anyText],
            actions: [.aiTransform(prompt: "把这段文字整理成排版规范、结构清楚的纯文本：短标题后面紧跟的简短内容合并成「标题：内容」一行；标题后面是长段落的，标题单独一行，正文另起一段；列举多项或步骤的内容改成编号或项目符号列表，一项一行；把语音转写、OCR 造成的句中断行接回去，统一空格和标点（中文用全角标点），修正明显的识别错误，段落之间只留一个空行。即使原文看起来已经整齐，也按这个格式整理一遍。保留原文语言和全部信息，不概括、不增删，不用 #、*、- 这类 Markdown 符号。")]
        ),
    ]
}
