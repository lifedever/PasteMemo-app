import Foundation
import SwiftData

enum TriggerMode: String, Codable, Sendable {
    case automatic
    case manual
}

enum ConditionLogic: String, Codable, Sendable {
    case all   // AND: all conditions must match
    case any   // OR: any condition must match
}

@Model
final class AutomationRule {
    var ruleID: String = UUID().uuidString
    var name: String = ""
    var enabled: Bool = true
    var isBuiltIn: Bool = false
    var sortOrder: Int = 0
    var triggerModeRaw: String = TriggerMode.automatic.rawValue
    var notifyBeforeApply: Bool = false
    var notifyOnTrigger: Bool = false
    var writeBackToPasteboard: Bool = false
    var conditionLogicRaw: String = ConditionLogic.all.rawValue
    var conditionsData: Data = Data()
    var actionsData: Data = Data()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Transient
    var triggerMode: TriggerMode {
        get { TriggerMode(rawValue: triggerModeRaw) ?? .automatic }
        set { triggerModeRaw = newValue.rawValue }
    }

    @Transient
    var conditionLogic: ConditionLogic {
        get { ConditionLogic(rawValue: conditionLogicRaw) ?? .all }
        set { conditionLogicRaw = newValue.rawValue }
    }

    var conditions: [RuleCondition] {
        get { (try? JSONDecoder().decode([RuleCondition].self, from: conditionsData)) ?? [] }
        set { conditionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var actions: [RuleAction] {
        get { (try? JSONDecoder().decode([RuleAction].self, from: actionsData)) ?? [] }
        set { actionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(
        name: String,
        enabled: Bool = true,
        isBuiltIn: Bool = false,
        sortOrder: Int = 0,
        triggerMode: TriggerMode = .automatic,
        notifyBeforeApply: Bool = false,
        writeBackToPasteboard: Bool = false,
        conditions: [RuleCondition] = [],
        actions: [RuleAction] = []
    ) {
        self.name = name
        self.enabled = enabled
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.triggerModeRaw = triggerMode.rawValue
        self.notifyBeforeApply = notifyBeforeApply
        self.writeBackToPasteboard = writeBackToPasteboard
        self.conditions = conditions
        self.actions = actions
    }

    /// Whether this rule should surface as an option for `item` in ⌘K / right-
    /// click menus. Two gates:
    /// 1. The rule's own conditions must match the clip (empty = always match).
    /// 2. Non-text clips (image, file, …) only surface rules that include at
    ///    least one `.runShortcut` action — built-in text transforms like
    ///    `lowercased` or `urlEncode` are meaningless on binary data.
    func matches(item: ClipItem) -> Bool {
        if !conditions.isEmpty {
            let ok = AutomationEngine.matchesConditions(
                conditions,
                logic: conditionLogic,
                content: item.content,
                contentType: item.contentType,
                sourceApp: item.sourceAppBundleID
            )
            guard ok else { return false }
        }
        if item.contentType.isMergeable { return true }
        return actions.contains { if case .runShortcut = $0 { return true }; return false }
    }
}
