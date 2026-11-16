import AppKit
import Foundation
import SwiftData
import Testing
@testable import PasteMemo

/// 内置「转为纯文本」规则和它依赖的「带格式」条件。
@Suite("Plain-text built-in rule")
@MainActor
struct PlainTextRuleTests {

    private static let RULE_NAME = "automation.builtIn.plainText"

    private final class Host: ActionHost {
        let source: ExecutionSource = .quickPanel
        let targetApp: NSRunningApplication? = nil
        func dismissPanel() {}
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([ClipItem.self, SmartGroup.self, AutomationRule.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: config))
    }

    private func richItem(_ content: String = "Hello") -> ClipItem {
        ClipItem(content: content, contentType: .text, richTextData: Data([1, 2, 3]), richTextType: "rtf",
                 pasteboardSnapshot: Data([9, 9]))
    }

    /// 内置规则表是私有的，走一遍真实的初次播种拿到它。播种读写 UserDefaults，
    /// 测完放回原值。
    private func seededRule(in context: ModelContext) throws -> AutomationRule {
        let seededKey = "builtInRulesSeeded_v2"
        let deletedKey = "builtInRulesDeleted"
        let defaults = UserDefaults.standard
        let savedSeeded = defaults.object(forKey: seededKey)
        let savedDeleted = defaults.object(forKey: deletedKey)
        defer {
            defaults.set(savedSeeded, forKey: seededKey)
            defaults.set(savedDeleted, forKey: deletedKey)
        }
        defaults.set(false, forKey: seededKey)
        defaults.removeObject(forKey: deletedKey)
        BuiltInRules.seedIfNeeded(context: context)
        let name = Self.RULE_NAME
        return try #require(try context.fetch(FetchDescriptor<AutomationRule>(predicate: #Predicate { $0.name == name })).first)
    }

    init() {
        ActionExecutor.showsToast = false
        ClipUndoCoordinator.showsToast = false
    }

    // MARK: - Condition

    @Test("hasRichText follows the input flag and needs clip context")
    func condition() {
        let plain = ConditionInput(content: "x", contentType: .text, sourceApp: nil)
        var rich = plain
        rich.hasRichText = true
        #expect(RuleCondition.hasRichText.matches(rich))
        #expect(!RuleCondition.hasRichText.matches(plain))
        #expect(RuleCondition.not(.hasRichText).matches(plain))
        #expect(RuleCondition.hasRichText.needsClipContext)
    }

    @Test("hasRichText survives an encode / decode round trip")
    func codable() throws {
        let conditions: [RuleCondition] = [.hasRichText, .not(.hasRichText)]
        let decoded = try JSONDecoder().decode([RuleCondition].self, from: JSONEncoder().encode(conditions))
        #expect(decoded == conditions)
    }

    @Test("ClipItem.hasRichText: either the type or the data counts")
    func itemFlag() {
        #expect(richItem().hasRichText)
        #expect(!ClipItem(content: "x", contentType: .text).hasRichText)
        // 老条目只有数据没有类型
        #expect(ClipItem(content: "x", contentType: .text, richTextData: Data([1])).hasRichText)
    }

    // MARK: - Built-in rule

    @Test("seeded as an enabled manual rule, offered only on text that carries formatting")
    func seededAndOffered() throws {
        let context = try makeContext()
        let rule = try seededRule(in: context)
        #expect(rule.isBuiltIn && rule.enabled)
        #expect(rule.triggerMode == .manual)
        #expect(rule.actions == [.stripRichText])

        #expect(rule.matches(item: richItem()))
        #expect(!rule.matches(item: ClipItem(content: "plain", contentType: .text)))
        let image = ClipItem(content: "[Image]", contentType: .image, richTextData: Data([1]), richTextType: "html")
        #expect(!rule.matches(item: image))
    }

    @Test("running it keeps the text and drops rich text plus the pasteboard snapshot")
    func strips() throws {
        let context = try makeContext()
        let rule = try seededRule(in: context)
        let item = richItem("第一行\n第二行")
        context.insert(item)

        ActionExecutor.apply(rule, to: [item], host: Host(), context: context)

        #expect(item.content == "第一行\n第二行")
        #expect(item.richTextData == nil)
        #expect(item.richTextType == nil)
        #expect(item.pasteboardSnapshot == nil)
        #expect(!rule.matches(item: item))
    }

    @Test("an existing install picks the rule up on the next launch")
    func seededForExistingUsers() throws {
        let context = try makeContext()
        let rule = try seededRule(in: context)
        context.delete(rule)
        try context.save()

        let defaults = UserDefaults.standard
        let savedSeeded = defaults.object(forKey: "builtInRulesSeeded_v2")
        let savedDeleted = defaults.object(forKey: "builtInRulesDeleted")
        defer {
            defaults.set(savedSeeded, forKey: "builtInRulesSeeded_v2")
            defaults.set(savedDeleted, forKey: "builtInRulesDeleted")
        }
        defaults.set(true, forKey: "builtInRulesSeeded_v2")
        defaults.removeObject(forKey: "builtInRulesDeleted")
        BuiltInRules.seedIfNeeded(context: context)

        let name = Self.RULE_NAME
        #expect(try context.fetch(FetchDescriptor<AutomationRule>(predicate: #Predicate { $0.name == name })).count == 1)
    }

    // MARK: - Capture path

    @Test("capture: the flag reaches conditions, and a strip earlier in the pass clears it")
    func capturePath() throws {
        let context = try makeContext()
        UserDefaults.standard.set(true, forKey: "automationEnabled")
        let tag = AutomationRule(name: "tag", sortOrder: 0, conditions: [.hasRichText], actions: [.addSuffix(text: " #rich")])
        context.insert(tag)
        try context.save()

        let rich = AutomationEngine.shared.process(content: "hi", contentType: .text, sourceApp: nil,
                                                   hasRichText: true, context: context)
        guard case .applied(let content, _, _, _, _) = rich else {
            Issue.record("expected .applied, got \(rich)")
            return
        }
        #expect(content == "hi #rich")
        let plain = AutomationEngine.shared.process(content: "hi", contentType: .text, sourceApp: nil, context: context)
        guard case .unchanged = plain else {
            Issue.record("expected .unchanged, got \(plain)")
            return
        }

        let strip = AutomationRule(name: "strip", sortOrder: -1, conditions: [.anyText], actions: [.stripRichText])
        context.insert(strip)
        try context.save()
        let stripped = AutomationEngine.shared.process(content: "hi", contentType: .text, sourceApp: nil,
                                                       hasRichText: true, context: context)
        guard case .applied(let afterStrip, _, _, _, _) = stripped else {
            Issue.record("expected .applied, got \(stripped)")
            return
        }
        #expect(afterStrip == "hi")
    }
}
