import Foundation
import SwiftData
import Testing
@testable import PasteMemo

@Suite("PasteMemo Tests")
struct PasteMemoTests {
    @Test("Detect text content type")
    @MainActor func detectText() {
        let result = ClipboardManager.shared.detectContentType("Hello world")
        #expect(result.type == .text)
    }

    @Test("Detect link content type")
    @MainActor func detectLink() {
        let result = ClipboardManager.shared.detectContentType("https://github.com")
        #expect(result.type == .link)
    }

    @Test("Detect color content type")
    @MainActor func detectColor() {
        let result = ClipboardManager.shared.detectContentType("#FF5733")
        #expect(result.type == .color)
    }

    @Test("Detect code content type")
    @MainActor func detectCode() {
        let code = """
        import Foundation
        func hello() {
            print("world")
        }
        """
        let result = ClipboardManager.shared.detectContentType(code)
        #expect(result.type == .code)
    }

    @Test("Reuse existing duplicate moves item to top without inserting a new row")
    @MainActor func reuseExistingDuplicateMovesToTop() throws {
        let container = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let originalDate = Date(timeIntervalSince1970: 100)
        let existing = ClipItem(
            content: "hello",
            contentType: .text,
            sourceApp: "Old App",
            createdAt: originalDate,
            lastUsedAt: originalDate
        )
        context.insert(existing)
        try context.save()

        let incoming = ClipItem(
            content: "hello",
            contentType: .text,
            sourceApp: "New App",
            createdAt: Date(timeIntervalSince1970: 200),
            lastUsedAt: Date(timeIntervalSince1970: 200)
        )

        let matched = ClipboardManager.shared.findExistingDuplicate(for: incoming, in: context)
        #expect(matched?.persistentModelID == existing.persistentModelID)

        ClipboardManager.shared.reuseExistingDuplicate(existing, with: incoming, in: context)
        try context.save()

        let items = try context.fetch(FetchDescriptor<ClipItem>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]))
        #expect(items.count == 1)
        #expect(items[0].persistentModelID == existing.persistentModelID)
        #expect(items[0].sourceApp == "New App")
        #expect(items[0].lastUsedAt > originalDate)
        #expect(items[0].createdAt == originalDate)
    }

    @Test("Plain text matches adjacent rich text duplicate and upgrades existing item")
    @MainActor func richTextDuplicateUpgradesExistingPlainItem() throws {
        let container = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let existing = ClipItem(
            content: "hello",
            contentType: .text,
            sourceApp: "Old App",
            createdAt: Date(timeIntervalSince1970: 100),
            lastUsedAt: Date(timeIntervalSince1970: 100)
        )
        context.insert(existing)
        try context.save()

        let richData = Data("{\\rtf1 rich}".utf8)
        let incoming = ClipItem(
            content: "hello",
            contentType: .text,
            sourceApp: "New App",
            createdAt: Date(timeIntervalSince1970: 200),
            lastUsedAt: Date(timeIntervalSince1970: 200),
            richTextData: richData,
            richTextType: "rtf"
        )

        let matched = ClipboardManager.shared.findExistingDuplicate(for: incoming, in: context)
        #expect(matched?.persistentModelID == existing.persistentModelID)

        ClipboardManager.shared.reuseExistingDuplicate(existing, with: incoming, in: context)
        try context.save()

        #expect(existing.richTextData == richData)
        #expect(existing.richTextType == "rtf")
        #expect(existing.sourceApp == "New App")
    }

    @Test("Rich text matches adjacent plain text duplicate without losing formatting")
    @MainActor func plainTextDuplicateKeepsExistingRichItem() throws {
        let container = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let richData = Data("<b>hello</b>".utf8)
        let existing = ClipItem(
            content: "hello",
            contentType: .text,
            sourceApp: "Old App",
            createdAt: Date(timeIntervalSince1970: 100),
            lastUsedAt: Date(timeIntervalSince1970: 100),
            richTextData: richData,
            richTextType: "html"
        )
        context.insert(existing)
        try context.save()

        let incoming = ClipItem(
            content: "hello",
            contentType: .text,
            sourceApp: "New App",
            createdAt: Date(timeIntervalSince1970: 200),
            lastUsedAt: Date(timeIntervalSince1970: 200)
        )

        let matched = ClipboardManager.shared.findExistingDuplicate(for: incoming, in: context)
        #expect(matched?.persistentModelID == existing.persistentModelID)

        ClipboardManager.shared.reuseExistingDuplicate(existing, with: incoming, in: context)
        try context.save()

        #expect(existing.richTextData == richData)
        #expect(existing.richTextType == "html")
        #expect(existing.sourceApp == "New App")
    }

    @Test("Different rich text payloads are not treated as duplicates")
    @MainActor func differentRichTextPayloadsRemainDistinct() throws {
        let container = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let existing = ClipItem(
            content: "hello",
            contentType: .text,
            richTextData: Data("<b>hello</b>".utf8),
            richTextType: "html"
        )
        context.insert(existing)
        try context.save()

        let incoming = ClipItem(
            content: "hello",
            contentType: .text,
            richTextData: Data("<i>hello</i>".utf8),
            richTextType: "html"
        )

        let matched = ClipboardManager.shared.findExistingDuplicate(for: incoming, in: context)
        #expect(matched == nil)
    }

    @Test("Retry OCR respects global OCR setting")
    @MainActor func retryOCRRespectsGlobalSetting() {
        let defaults = UserDefaults.standard
        let key = OCRTaskCoordinator.enableOCRKey
        let original = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let item = ClipItem(content: "[Image]", contentType: .image, imageData: Data([1]))
        #expect(!OCRTaskCoordinator.shared.canRetry(item: item))
    }

    @Test("Image clip defaults to pending OCR status")
    @MainActor func imageClipDefaultsToPendingOCR() {
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let item = ClipItem(content: "[Image]", contentType: .image, imageData: data)
        #expect(item.resolvedOCRStatus == .pending)
    }

    @Test("DataPorter preserves OCR metadata")
    @MainActor func dataPorterPreservesOCRMetadata() throws {
        let clip = ClipItem(content: "[Image]", contentType: .image, imageData: Data([1, 2, 3]))
        clip.ocrText = "hello from image"
        clip.ocrStatus = OCRStatus.done.rawValue
        clip.ocrErrorMessage = nil
        clip.ocrUpdatedAt = Date(timeIntervalSince1970: 100)
        clip.ocrVersion = 2

        let exported = DataPorter.buildSingleExportItem(clip)
        #expect(exported.ocrText == "hello from image")
        #expect(exported.ocrStatus == OCRStatus.done.rawValue)
        #expect(exported.ocrVersion == 2)
    }

    @Test("OCR-only match ignores title/content hits")
    @MainActor func ocrOnlyMatchDetection() {
        let item = ClipItem(content: "[Image]", contentType: .image, imageData: Data([1]))
        item.displayTitle = "Image (100x100)"
        item.ocrText = "build failed on line 42"

        #expect(item.matchesOCROnly(searchText: "line 42"))
        #expect(!item.matchesOCROnly(searchText: "Image"))
        #expect(!item.matchesOCROnly(searchText: ""))
    }

    @Test("Quick preview OCR snippet includes match context")
    @MainActor func quickPreviewOCRSnippet() {
        let attributed = QuickPreviewPane.buildOCRSnippet(
            text: "first line of text\nerror happened on line 42 near the prompt\nlast line",
            query: "line 42"
        )
        let snippet = String(attributed.characters)
        #expect(snippet.contains("line 42"))
        #expect(snippet.contains("error happened"))
    }

    @Test("Quick preview OCR snippet falls back to compact prefix when query is missing")
    @MainActor func quickPreviewOCRSnippetWithoutMatch() {
        let text = Array(repeating: "0123456789", count: 30).joined()
        let attributed = QuickPreviewPane.buildOCRSnippet(text: text, query: "missing")
        let snippet = String(attributed.characters)

        #expect(snippet.count <= 221)
        #expect(snippet.hasPrefix("0123456789"))
    }

    @Test("Quick preview code summary captures language, counts and truncation")
    @MainActor func quickPreviewCodeSummary() {
        let code = """
        import Foundation
        struct Demo {
            func run() {
                print("hello")
            }
        }
        """

        let summary = QuickPreviewPane.buildCodeSummary(text: code, language: .swift, previewLineLimit: 3, previewCharacterLimit: 80)

        #expect(summary.language == .swift)
        #expect(summary.lineCount == 6)
        #expect(summary.characterCount == code.count)
        #expect(summary.isTruncated)
        #expect(summary.snippet.contains("import Foundation"))
        #expect(summary.snippet.hasSuffix("…"))
    }

    @Test("Quick preview code summary disables expanded preview for very large code")
    @MainActor func quickPreviewCodeSummaryDisablesExpandedPreview() {
        let code = Array(repeating: "let value = 1", count: 4000).joined(separator: "\n")

        let summary = QuickPreviewPane.buildCodeSummary(text: code, language: .swift, expandedPreviewCharacterLimit: 5000)

        #expect(!summary.supportsExpandedPreview)
    }

    @Test("Quick preview link summary strips www and preserves path/query")
    @MainActor func quickPreviewLinkSummaryHelpers() {
        let url = URL(string: "https://www.example.com/docs/page?ref=abc&lang=en")!

        #expect(QuickPreviewPane.displayHost(for: url) == "example.com")
        #expect(QuickPreviewPane.displayPath(for: url) == "/docs/page?ref=abc&lang=en")
    }

    @Test("OCR language list prioritizes Chinese when app language is Chinese")
    func ocrLanguagePriorityForChinese() {
        let languages = ImageOCRService.preferredRecognitionLanguages(appLanguage: "zh-Hans")
        #expect(languages.first == "zh-Hans")
        #expect(languages.contains("zh-Hant"))
        #expect(languages.contains("en-US"))
    }

    @Test("Open in Preview excludes archive and application items")
    @MainActor func openInPreviewSupportedTypes() {
        let archive = ClipItem(content: "/tmp/test.zip", contentType: .archive)
        let application = ClipItem(content: "/Applications/Test.app", contentType: .application)
        let document = ClipItem(content: "/tmp/test.pdf", contentType: .document)
        let image = ClipItem(content: "[Image]", contentType: .image, imageData: Data([1]))

        #expect(!QuickLookHelper.shared.canOpenInPreview(item: archive))
        #expect(!QuickLookHelper.shared.canOpenInPreview(item: application))
        #expect(QuickLookHelper.shared.canOpenInPreview(item: document))
        #expect(QuickLookHelper.shared.canOpenInPreview(item: image))
    }

}

@Suite("RelayItem Tests")
struct RelayItemTests {
    @Test("Init sets pending state")
    func initState() {
        let item = RelayItem(content: "test")
        #expect(item.state == .pending)
        #expect(item.content == "test")
        #expect(!item.id.uuidString.isEmpty)
    }
}

@Suite("RelaySplitter Tests")
struct RelaySplitterTests {
    @Test("Split by newline")
    func splitNewline() {
        let result = RelaySplitter.split("A\nB\nC", by: .newline)
        #expect(result == ["A", "B", "C"])
    }

    @Test("Split by comma")
    func splitComma() {
        let result = RelaySplitter.split("张三,李四,王五", by: .comma)
        #expect(result == ["张三", "李四", "王五"])
    }

    @Test("Split by Chinese comma")
    func splitChineseComma() {
        let result = RelaySplitter.split("张三、李四、王五", by: .chineseComma)
        #expect(result == ["张三", "李四", "王五"])
    }

    @Test("Split by custom delimiter")
    func splitCustom() {
        let result = RelaySplitter.split("A|B|C", by: .custom("|"))
        #expect(result == ["A", "B", "C"])
    }

    @Test("Filter empty strings from consecutive delimiters")
    func filterEmpty() {
        let result = RelaySplitter.split("A,,B,,C", by: .comma)
        #expect(result == ["A", "B", "C"])
    }

    @Test("Trim whitespace from results")
    func trimWhitespace() {
        let result = RelaySplitter.split("A , B , C", by: .comma)
        #expect(result == ["A", "B", "C"])
    }

    @Test("Return nil when delimiter not found")
    func noDelimiter() {
        let result = RelaySplitter.split("Hello World", by: .comma)
        #expect(result == nil)
    }

    @Test("Return nil for single result")
    func singleResult() {
        let result = RelaySplitter.split("Hello,", by: .comma)
        #expect(result == nil)
    }
}

@Suite("RelayManager Tests")
struct RelayManagerTests {
    @Test("Enqueue items")
    @MainActor func enqueue() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        #expect(manager.items.count == 3)
        #expect(manager.items[0].state == .current)
        #expect(manager.items[1].state == .pending)
    }

    @Test("Advance moves pointer forward")
    @MainActor func advance() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        let item = manager.advance()
        #expect(item?.content == "A")
        #expect(manager.items[0].state == .done)
        #expect(manager.items[1].state == .current)
        #expect(manager.currentIndex == 1)
    }

    @Test("Advance returns nil when exhausted")
    @MainActor func advanceExhausted() {
        let manager = makeManager()
        manager.enqueue(texts: ["A"])
        _ = manager.advance()
        let item = manager.advance()
        #expect(item == nil)
        #expect(manager.isQueueExhausted)
    }

    @Test("Skip marks current as skipped")
    @MainActor func skip() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B"])
        manager.skip()
        #expect(manager.items[0].state == .skipped)
        #expect(manager.items[1].state == .current)
    }

    @Test("Rollback moves pointer backward")
    @MainActor func rollback() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        _ = manager.advance()
        manager.rollback()
        #expect(manager.currentIndex == 0)
        #expect(manager.items[0].state == .current)
    }

    @Test("Rollback resets skipped items")
    @MainActor func rollbackSkipped() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        manager.skip()
        manager.rollback()
        #expect(manager.items[0].state == .current)
    }

    @Test("Delete removes item and adjusts pointer")
    @MainActor func deleteItem() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        _ = manager.advance()
        manager.deleteItem(at: 0)
        #expect(manager.items.count == 2)
        #expect(manager.currentIndex == 0)
        #expect(manager.items[0].state == .current)
        #expect(manager.items[0].content == "B")
    }

    @Test("Move reorders items")
    @MainActor func moveItem() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        manager.moveItem(from: Foundation.IndexSet(integer: 2), to: 0)
        #expect(manager.items[0].content == "C")
    }

    @Test("Split replaces item with multiple")
    @MainActor func splitItem() {
        let manager = makeManager()
        manager.enqueue(texts: ["张三,李四,王五"])
        let success = manager.splitItem(at: 0, by: .comma)
        #expect(success)
        #expect(manager.items.count == 3)
        #expect(manager.items[0].content == "张三")
    }

    @Test("Progress string")
    @MainActor func progress() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        _ = manager.advance()
        #expect(manager.progressText == "1/3")
    }
}

// RelayManager.shared is singleton, so create fresh instances for tests
@MainActor
private func makeManager() -> RelayManager {
    let manager = RelayManager.shared
    manager.deactivate()
    manager.items.removeAll()
    manager.currentIndex = 0
    return manager
}
