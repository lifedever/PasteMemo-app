import AppKit
import Foundation
import SwiftData
import Testing
@testable import PasteMemo

/// The single manual-apply path (⌘K / context menu in both windows): output modes,
/// set-semantics metadata, type gating, and the rule-model plumbing it relies on
/// (lenient decoding, output-mode fallback, `matches(item:)`).
@Suite("ActionExecutor")
@MainActor
struct ActionExecutorTests {

    private final class RecordingHost: ActionHost {
        let source: ExecutionSource
        let targetApp: NSRunningApplication? = nil
        var dismissCount = 0
        init(source: ExecutionSource = .quickPanel) { self.source = source }
        func dismissPanel() { dismissCount += 1 }
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([ClipItem.self, SmartGroup.self, AutomationRule.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: config))
    }

    private func makeRule(_ actions: [RuleAction], output: RuleOutputMode = .replaceItem) -> AutomationRule {
        let rule = AutomationRule(name: "t", triggerMode: .manual, actions: actions)
        rule.outputMode = output
        return rule
    }

    init() { ActionExecutor.showsToast = false }

    // MARK: - Output modes

    @Test("replaceItem rewrites the clip in place and drops stale rich text")
    func replaceItem() throws {
        let context = try makeContext()
        let item = ClipItem(content: "HELLO", contentType: .text, richTextData: Data([1, 2]), richTextType: "rtf")
        context.insert(item)

        ActionExecutor.apply(makeRule([.lowercased]), to: [item], host: RecordingHost(), context: context)

        #expect(item.content == "hello")
        #expect(item.richTextData == nil)
        #expect(item.richTextType == nil)
        #expect(try context.fetch(FetchDescriptor<ClipItem>()).count == 1)
    }

    @Test("newItem leaves the original alone and inserts the result; metadata lands on the new clip")
    func newItem() throws {
        let context = try makeContext()
        let item = ClipItem(content: "HELLO", contentType: .text, sourceAppBundleID: "com.apple.Safari")
        context.insert(item)

        ActionExecutor.apply(makeRule([.lowercased, .pin], output: .newItem), to: [item], host: RecordingHost(), context: context)

        let all = try context.fetch(FetchDescriptor<ClipItem>())
        #expect(all.count == 2)
        #expect(item.content == "HELLO")
        #expect(!item.isPinned)
        let created = try #require(all.first { $0 !== item })
        #expect(created.content == "hello")
        #expect(created.isPinned)
        #expect(created.sourceAppBundleID == "com.apple.Safari")
    }

    @Test("newItem with unchanged text creates nothing — metadata goes to the original")
    func newItemNoChange() throws {
        let context = try makeContext()
        let item = ClipItem(content: "hello", contentType: .text)
        context.insert(item)

        ActionExecutor.apply(makeRule([.lowercased, .pin], output: .newItem), to: [item], host: RecordingHost(), context: context)

        #expect(try context.fetch(FetchDescriptor<ClipItem>()).count == 1)
        #expect(item.isPinned)
    }

    // MARK: - Metadata set-semantics

    @Test("pin / unpin and markSensitive / unmarkSensitive are sets, not toggles")
    func setSemantics() throws {
        let context = try makeContext()
        let item = ClipItem(content: "x", contentType: .text, isPinned: true)
        item.isSensitive = true
        context.insert(item)

        ActionExecutor.applyMetadata([.pin, .markSensitive], to: item, context: context)
        #expect(item.isPinned && item.isSensitive)

        ActionExecutor.applyMetadata([.unpin, .unmarkSensitive], to: item, context: context)
        #expect(!item.isPinned && !item.isSensitive)
    }

    @Test("text transforms are skipped on an image; metadata still applies")
    func imageKeepsPlaceholder() throws {
        let context = try makeContext()
        let item = ClipItem(content: "[Image]", contentType: .image)
        context.insert(item)

        ActionExecutor.apply(makeRule([.uppercased, .pin]), to: [item], host: RecordingHost(), context: context)

        #expect(item.content == "[Image]")
        #expect(item.isPinned)
    }

    @Test("multi-select applies to every clip")
    func multiSelect() throws {
        let context = try makeContext()
        let a = ClipItem(content: "A", contentType: .text)
        let b = ClipItem(content: "B", contentType: .text)
        context.insert(a); context.insert(b)

        ActionExecutor.apply(makeRule([.lowercased]), to: [a, b], host: RecordingHost(), context: context)

        #expect(a.content == "a")
        #expect(b.content == "b")
    }

    @Test("closeQuickPanel dismisses the host once the rule applied")
    func closePanel() throws {
        let context = try makeContext()
        let item = ClipItem(content: "A", contentType: .text)
        context.insert(item)
        let host = RecordingHost()

        ActionExecutor.apply(makeRule([.lowercased, .closeQuickPanel]), to: [item], host: host, context: context)

        #expect(host.dismissCount == 1)
    }

    @Test("a rule that changes nothing and has no metadata leaves the clip and the panel alone")
    func noOpRule() throws {
        let context = try makeContext()
        let item = ClipItem(content: "already", contentType: .text)
        context.insert(item)
        let host = RecordingHost()

        ActionExecutor.apply(makeRule([.lowercased, .closeQuickPanel]), to: [item], host: host, context: context)

        // closeQuickPanel is a side effect, so the rule counts as applied even with unchanged text.
        #expect(host.dismissCount == 1)
        #expect(item.content == "already")
    }

    // MARK: - Engine: stopProcessing

    @Test("stopProcessing halts the automatic chain after its rule")
    func stopProcessing() throws {
        let context = try makeContext()
        UserDefaults.standard.set(true, forKey: "automationEnabled")
        let first = AutomationRule(name: "up", sortOrder: 0, conditions: [.anyText], actions: [.uppercased, .stopProcessing])
        let second = AutomationRule(name: "prefix", sortOrder: 1, conditions: [.anyText], actions: [.addPrefix(text: ">")])
        context.insert(first); context.insert(second)
        try context.save()

        let result = AutomationEngine.shared.process(content: "hi", contentType: .text, sourceApp: nil, context: context)

        guard case .applied(let content, _, _, _) = result else {
            Issue.record("expected .applied, got \(result)")
            return
        }
        #expect(content == "HI")
    }

    // MARK: - Rule model plumbing

    @Test("unknown actions are dropped element-wise, not the whole rule")
    func lenientDecoding() {
        let rule = AutomationRule(name: "t")
        let json = #"[{"lowercased":{}},{"aiTransformFromTheFuture":{"prompt":"x"}},{"pin":{}}]"#
        rule.actionsData = Data(json.utf8)
        #expect(rule.actions == [.lowercased, .pin])
    }

    @Test("outputMode falls back to the legacy writeBack flag and keeps it in sync")
    func outputModeFallback() {
        let rule = AutomationRule(name: "t", writeBackToPasteboard: true)
        #expect(rule.outputMode == .clipboard)

        rule.outputMode = .replaceItem
        #expect(!rule.writeBackToPasteboard)
        rule.outputMode = .pasteToFrontmost
        #expect(rule.writeBackToPasteboard)
    }

    @Test("matches(item:) gates by inputKind: text transforms hide on images, metadata shows everywhere")
    func matchesByInputKind() {
        let image = ClipItem(content: "[Image]", contentType: .image)
        let text = ClipItem(content: "hi", contentType: .text)
        #expect(!AutomationRule(name: "t", actions: [.lowercased]).matches(item: image))
        #expect(AutomationRule(name: "t", actions: [.pin]).matches(item: image))
        #expect(AutomationRule(name: "t", actions: [.runShortcut(name: "x")]).matches(item: image))
        #expect(AutomationRule(name: "t", actions: [.lowercased]).matches(item: text))
    }

    @Test("descriptor dimensions: manual-only actions and kinds")
    func descriptors() {
        #expect(RuleAction.runShortcut(name: "x").requiresManualTrigger)
        #expect(RuleAction.closeQuickPanel.requiresManualTrigger)
        #expect(!RuleAction.lowercased.requiresManualTrigger)
        #expect(RuleAction.lowercased.kind == .transform)
        #expect(RuleAction.assignGroup(name: "g").kind == .metadata)
        #expect(RuleAction.stopProcessing.kind == .sideEffect)
        #expect(!AutomationEngine.containsSpecialAction([.runShortcut(name: "x"), .lowercased]))
        #expect(AutomationEngine.containsSpecialAction([.stopProcessing]))
    }
}
