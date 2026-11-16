import AppKit
import Foundation
import SwiftData
import Testing
@testable import PasteMemo

@Suite("Split rules")
struct ClipSplitterTests {

    private let prompts = """
    1. 从第一性原理出发，找到最本质原因，修复一下。
    2. 先问一些不清晰的问题，对齐我的喜好，然后再出3版方案。
    3.不要默认我提出的问题定义就是正确的。
    10. 全面复盘最近XX时间的 Bug、返工、回滚和重复修改。
    """

    private func split(_ text: String, _ rule: ClipSplitter.Rule, strip: Bool = false) -> ClipSplitter.Result {
        ClipSplitter.split(text, rule: rule, stripNumbering: strip)
    }

    @Test("auto picks numbered items; strip removes the markers, `3.不要` included")
    func numberedPrompts() {
        let kept = split(prompts, .auto)
        #expect(kept.resolved == .numbered)
        #expect(kept.pieces.count == 4)
        #expect(kept.pieces[2] == "3.不要默认我提出的问题定义就是正确的。")
        #expect(kept.canStripNumbering)

        let stripped = split(prompts, .auto, strip: true)
        #expect(stripped.pieces == [
            "从第一性原理出发，找到最本质原因，修复一下。",
            "先问一些不清晰的问题，对齐我的喜好，然后再出3版方案。",
            "不要默认我提出的问题定义就是正确的。",
            "全面复盘最近XX时间的 Bug、返工、回滚和重复修改。",
        ])
    }

    @Test("numbered: wrapped lines and indented sub-bullets stay with their item; preamble is its own piece")
    func numberedContinuation() {
        let text = """
        周会纪要 11/16
        1. 拆分功能先出网页 demo
           负责人：小周，周三前给到
        2. 撤销统一
           - 都弹同一种 toast
           - 8 秒
        3. 1.17.1 周五发 beta
        """
        let result = split(text, .numbered, strip: true)
        #expect(result.pieces == [
            "周会纪要 11/16",
            "拆分功能先出网页 demo\n负责人：小周，周三前给到",
            "撤销统一\n- 都弹同一种 toast\n- 8 秒",
            "1.17.1 周五发 beta",
        ])
    }

    @Test("decimals and dates aren't list markers")
    func notMarkers() {
        let result = split("价格涨了 1.5 倍\n2026.11.16 记录", .numbered)
        #expect(result.pieces.count == 1)
        #expect(!result.canStripNumbering)
    }

    @Test("auto falls back to paragraphs, then lines, then a short-piece delimiter")
    func autoFallbacks() {
        let paragraphs = split("各位好：\n\n周五断电维护。\n  \n有问题找 IT。", .auto)
        #expect(paragraphs.resolved == .paragraph)
        #expect(paragraphs.pieces == ["各位好：", "周五断电维护。", "有问题找 IT。"])

        let lines = split("a\nb\r\nc", .auto)
        #expect(lines.resolved == .line)
        #expect(lines.pieces == ["a", "b", "c"])

        let tags = split("Swift、SwiftUI、AppKit", .auto)
        #expect(tags.resolved == .delimiter(.chineseComma))
        #expect(tags.pieces == ["Swift", "SwiftUI", "AppKit"])

        // An ordinary sentence with a comma stays whole.
        let sentence = split("今天先把拆分做完，明天再看撤销的边界情况和测试覆盖，顺便整理一下文档和发版说明", .auto)
        #expect(sentence.pieces.count == 1)
        #expect(sentence.resolved == nil)
        #expect(!sentence.isSplittable)
    }

    @Test("delimiters: full- and half-width alike, custom literal, blanks and duplicates dropped")
    func delimiters() {
        #expect(split("a,b，c", .delimiter(.comma)).pieces == ["a", "b", "c"])
        #expect(split("a;b；c", .delimiter(.semicolon)).pieces == ["a", "b", "c"])
        #expect(split("a || b ||  || a", .delimiter(.custom("||"))).pieces == ["a", "b"])
        #expect(split("a,b", .delimiter(.custom(""))).pieces == ["a,b"])
    }

    @Test("regex: cut and drop the match; a lookahead keeps it; ^ matches each line")
    func regex() {
        let chat = """
        [10:01] 小周：拆分好了吗
        [10:02] 我：快好了
        续行也算这一条
        [10:05] 小周：好
        """
        let result = split(chat, .regex(#"(?=^\[\d\d:\d\d\])"#))
        #expect(result.pieces == [
            "[10:01] 小周：拆分好了吗",
            "[10:02] 我：快好了\n续行也算这一条",
            "[10:05] 小周：好",
        ])
        #expect(split("a1b22c", .regex(#"\d+"#)).pieces == ["a", "b", "c"])
    }

    @Test("a broken pattern is reported, an empty one leaves the text whole")
    func badRegex() {
        let bad = split("a b", .regex("(["))
        #expect(bad.invalidPattern)
        #expect(!bad.isSplittable)
        #expect(split("a b", .regex("")).pieces == ["a b"])
    }

    @Test("more than MAX_PIECES pieces is refused")
    func overLimit() {
        let text = (0..<(ClipSplitter.MAX_PIECES + 5)).map(String.init).joined(separator: "\n")
        let result = split(text, .line)
        #expect(result.isOverLimit)
        #expect(!result.isSplittable)
    }
}

@Suite("Split clips and undo", .serialized)
@MainActor
struct ClipSplitApplyTests {

    init() {
        ClipUndoCoordinator.showsToast = false
        ActionExecutor.showsToast = false
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([ClipItem.self, SmartGroup.self, AutomationRule.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: config))
    }

    private func all(_ context: ModelContext) throws -> [ClipItem] {
        try context.fetch(FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]))
    }

    @Test("what can be split: text, multi-file clips; not raw images, single files, blank text, deleted clips")
    func canSplit() throws {
        let context = try makeContext()
        func stored(_ content: String, _ type: ClipContentType) -> ClipItem {
            let item = ClipItem(content: content, contentType: type)
            context.insert(item)
            return item
        }
        #expect(ClipSplit.canSplit(stored("a\nb", .text)))
        #expect(ClipSplit.canSplit(stored("/tmp/a.pdf\n/tmp/b.pdf", .document)))
        #expect(!ClipSplit.canSplit(stored("/tmp/a.pdf", .document)))
        #expect(!ClipSplit.canSplit(stored("[Image]", .image)))
        #expect(!ClipSplit.canSplit(stored("  \n ", .text)))
        #expect(!ClipSplit.canSplit(ClipItem(content: "a\nb", contentType: .text)))
    }

    @Test("pieces replace the clip top to bottom, keep its app, group and sensitive mark, and get their own type")
    func applyText() throws {
        let context = try makeContext()
        let source = ClipItem(content: "first\nhttps://example.com\nthird", contentType: .text,
                              sourceApp: "微信", sourceAppBundleID: "com.tencent.xinWeChat")
        source.groupName = "Prompts"
        source.isSensitive = true
        source.isPinned = true
        context.insert(source)
        try context.save()

        let pieces = ["first", "https://example.com", "third"]
        let result = ClipSplit.apply(pieces, replacing: source, in: context)

        #expect(result.map(\.content) == pieces)
        let stored = try all(context)
        #expect(stored.map(\.content) == pieces)
        #expect(stored.allSatisfy { $0.sourceAppBundleID == "com.tencent.xinWeChat" && $0.groupName == "Prompts" })
        #expect(stored.allSatisfy { $0.isSensitive })
        #expect(stored.allSatisfy { !$0.isPinned })
        #expect(stored[1].contentType == .link)
    }

    @Test("a piece already in the history brings that clip up instead of a copy; undo puts everything back")
    func dedupAndUndo() throws {
        let context = try makeContext()
        let old = Date(timeIntervalSinceNow: -3600)
        let existing = ClipItem(content: "b", contentType: .text, createdAt: old, lastUsedAt: old)
        let source = ClipItem(content: "a\nb\nc", contentType: .text, richTextData: Data([1]), richTextType: "rtf")
        [existing, source].forEach(context.insert)
        try context.save()
        let sourceID = source.itemID

        let result = ClipSplit.apply(["a", "b", "c"], replacing: source, in: context)
        #expect(result[1] === existing)
        #expect(existing.lastUsedAt > old)
        #expect(try all(context).map(\.content) == ["a", "b", "c"])

        ClipUndoCoordinator.shared.undo()

        let restored = try all(context)
        #expect(restored.map(\.content) == ["a\nb\nc", "b"])
        let original = try #require(restored.first)
        #expect(original.itemID == sourceID)
        #expect(original.richTextType == "rtf")
        #expect(existing.lastUsedAt == old)
    }

    @Test("a multi-file clip splits into one clip per file")
    func applyFiles() throws {
        let context = try makeContext()
        let source = ClipItem(content: "/tmp/a.pdf\n/tmp/b.zip", contentType: .file)
        context.insert(source)
        try context.save()

        ClipSplit.apply(["/tmp/a.pdf", "/tmp/b.zip"], replacing: source, in: context)

        let stored = try all(context)
        #expect(stored.map(\.content) == ["/tmp/a.pdf", "/tmp/b.zip"])
        #expect(stored.map(\.contentType) == [.document, .archive])
    }

    @Test("merge is undoable: the originals come back and the merged clip goes")
    func mergeUndo() throws {
        let context = try makeContext()
        let top = ClipItem(content: "top")
        let below = ClipItem(content: "below", createdAt: Date(timeIntervalSinceNow: -60),
                             lastUsedAt: Date(timeIntervalSinceNow: -60))
        [top, below].forEach(context.insert)
        try context.save()

        _ = try #require(ClipMerge.merge([top, below], in: context))
        #expect(try all(context).map(\.content) == ["top\nbelow"])

        ClipUndoCoordinator.shared.undo()
        #expect(try all(context).map(\.content) == ["top", "below"])
    }

    @Test("a manual rule that rewrote a clip is undoable, rich text included")
    func ruleUndo() throws {
        let context = try makeContext()
        let item = ClipItem(content: "HELLO", contentType: .text, richTextData: Data([1, 2]), richTextType: "rtf",
                            pasteboardSnapshot: Data([9]))
        context.insert(item)
        try context.save()
        let rule = AutomationRule(name: "lower", triggerMode: .manual, actions: [.lowercased, .pin])

        ActionExecutor.apply(rule, to: [item], host: PlainActionHost(source: .mainWindow), context: context)
        #expect(item.content == "hello" && item.isPinned && item.richTextData == nil)

        ClipUndoCoordinator.shared.undo()
        #expect(item.content == "HELLO")
        #expect(!item.isPinned)
        #expect(item.richTextData == Data([1, 2]))
        #expect(item.richTextType == "rtf")
        #expect(item.pasteboardSnapshot == Data([9]))
    }

    @Test("a metadata-only rule is undoable and leaves the rich text it never read alone")
    func metadataRuleUndo() throws {
        let context = try makeContext()
        let item = ClipItem(content: "keep", contentType: .text, richTextData: Data([4, 2]), richTextType: "rtf")
        context.insert(item)
        try context.save()

        ActionExecutor.apply(AutomationRule(name: "pin", triggerMode: .manual, actions: [.pin]),
                             to: [item], host: PlainActionHost(source: .mainWindow), context: context)
        #expect(item.isPinned)

        ClipUndoCoordinator.shared.undo()
        #expect(!item.isPinned)
        #expect(item.richTextData == Data([4, 2]))
        #expect(item.richTextType == "rtf")
    }

    @Test("a rule that changed nothing offers no undo")
    func ruleNoChange() throws {
        let context = try makeContext()
        let item = ClipItem(content: "hello", contentType: .text)
        context.insert(item)
        try context.save()
        let first = ClipItem(content: "keep me", contentType: .text)
        context.insert(first)
        try context.save()
        ClipUndoCoordinator.shared.scheduleUndoableDelete(items: [first], context: context)

        // Lowercasing lowercase text does nothing — the pending delete undo stays the latest.
        ActionExecutor.apply(AutomationRule(name: "lower", triggerMode: .manual, actions: [.lowercased]),
                             to: [item], host: PlainActionHost(source: .mainWindow), context: context)
        ClipUndoCoordinator.shared.undo()
        #expect(try all(context).contains { $0.content == "keep me" })
    }

    @Test("an edit is undoable")
    func editUndo() throws {
        let context = try makeContext()
        let item = ClipItem(content: "draft", contentType: .text, richTextData: Data([7]), richTextType: "html")
        context.insert(item)
        try context.save()

        #expect(ClipboardManager.shared.saveEdit("final", to: item, context: context))
        #expect(item.content == "final" && item.richTextData == nil)

        ClipUndoCoordinator.shared.undo()
        #expect(item.content == "draft")
        #expect(item.richTextType == "html")
    }

    @Test("only the latest change can be undone; a new one makes the previous permanent")
    func latestOnly() throws {
        let context = try makeContext()
        let a = ClipItem(content: "a")
        let b = ClipItem(content: "b")
        [a, b].forEach(context.insert)
        try context.save()

        ClipUndoCoordinator.shared.scheduleUndoableDelete(items: [a], context: context)
        ClipUndoCoordinator.shared.scheduleUndoableDelete(items: [b], context: context)
        ClipUndoCoordinator.shared.undo()
        ClipUndoCoordinator.shared.undo()   // nothing left to undo

        #expect(try all(context).map(\.content) == ["b"])
    }
}
