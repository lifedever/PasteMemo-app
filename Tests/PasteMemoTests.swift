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

    @Test("Snippet title falls back to first non-empty content line")
    @MainActor func snippetResolvedTitleFallsBackToContent() {
        let snippet = SnippetItem(title: "", content: "\n  hello world  \nsecond line", contentType: .text)
        #expect(snippet.resolvedTitle == "hello world")
    }

    @Test("Snippet title fallback uses localized untitled label when content is empty")
    @MainActor func snippetResolvedTitleUsesLocalizedUntitledFallback() {
        let previousLanguage = LanguageManager.shared.current
        defer { LanguageManager.shared.setLanguage(previousLanguage) }

        LanguageManager.shared.setLanguage("zh-Hans")

        let snippet = SnippetItem(title: "   ", content: "\n\n", contentType: .text)
        #expect(snippet.resolvedTitle == "未命名片段")
    }

    @Test("All supported languages include snippet localization keys")
    @MainActor func allSupportedLanguagesIncludeSnippetLocalizationKeys() {
        let requiredKeys = [
            "snippet.new",
            "snippet.saveAs",
            "snippet.saved",
            "snippet.delete",
            "snippet.titlePlural",
            "snippet.count",
            "snippet.titlePlaceholder",
            "snippet.typeLabel",
            "snippet.groupLabel",
            "snippet.groupPlaceholder",
            "snippet.groupNone",
            "snippet.groupChoose",
            "snippet.groupClear",
            "snippet.tagsLabel",
            "snippet.tagsPlaceholder",
            "snippet.tagsPrompt",
            "snippet.addTags",
            "snippet.removeTags",
            "snippet.duplicateTitle",
            "snippet.duplicateMessage",
            "snippet.updateExisting",
            "snippet.createNew",
            "snippet.contentLabel",
            "snippet.empty",
            "snippet.unused",
            "snippet.usedCount",
            "snippet.untitled",
            "snippet.badge",
            "snippet.namePromptTitle",
            "snippet.namePromptMessage",
            "quick.switchScope",
            "quick.switchToSnippets",
            "quick.switchToHistory",
            "quick.switchSearchSection",
            "quick.switchSnippetSort",
            "quick.snippetMove",
        ]

        var missing: [String] = []

        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectRoot = testsDir.deletingLastPathComponent()
        let localizationRoot = projectRoot.appendingPathComponent("Sources/Localization", isDirectory: true)

        for code in L10n.supportedLanguages.map(\.code) {
            let fileURL = localizationRoot
                .appendingPathComponent("\(code).lproj", isDirectory: true)
                .appendingPathComponent("Localizable.strings", isDirectory: false)

            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                missing.append("\(code):file")
                continue
            }

            for key in requiredKeys where !contents.contains("\"\(key)\"") {
                missing.append("\(code):\(key)")
            }
        }

        #expect(missing.isEmpty)
    }

    @Test("Save as snippet copies core clip fields")
    @MainActor func saveAsSnippetCopiesClipFields() throws {
        let container = try ModelContainer(
            for: ClipItem.self, SnippetItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let clip = ClipItem(
            content: "hello snippet",
            contentType: .code,
            sourceApp: "Xcode",
            isPinned: true,
            richTextData: Data("<b>hello</b>".utf8),
            richTextType: "html"
        )
        clip.displayTitle = "Greeting"
        clip.groupName = "Dev"

        let snippet = SnippetLibrary.createSnippet(from: clip, in: context)

        #expect(snippet.title == "Greeting")
        #expect(snippet.content == "hello snippet")
        #expect(snippet.contentType == .code)
        #expect(snippet.groupName == "Dev")
        #expect(snippet.isPinned)
        #expect(snippet.richTextType == "html")
        #expect(snippet.richTextData == Data("<b>hello</b>".utf8))
    }

    @Test("Save as snippet uses custom title when provided")
    @MainActor func saveAsSnippetUsesCustomTitle() throws {
        let container = try ModelContainer(
            for: ClipItem.self, SnippetItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let clip = ClipItem(content: "hello snippet", contentType: .text)
        clip.displayTitle = "Original"

        let snippet = SnippetLibrary.saveSnippet(from: clip, title: "Pinned Greeting", in: context) { _ in .createNew }

        #expect(snippet?.title == "Pinned Greeting")
    }

    @Test("Save as snippet falls back to suggested title when custom title is empty")
    @MainActor func saveAsSnippetFallsBackToSuggestedTitleWhenCustomTitleEmpty() throws {
        let container = try ModelContainer(
            for: ClipItem.self, SnippetItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let clip = ClipItem(content: "\n  hello snippet  ", contentType: .text)
        clip.displayTitle = ""

        let snippet = SnippetLibrary.saveSnippet(from: clip, title: "   ", in: context) { _ in .createNew }

        #expect(snippet?.title == "hello snippet")
    }

    @Test("Snippet tags parse and deduplicate")
    @MainActor func snippetTagsParseAndDeduplicate() {
        let parsed = SnippetItem.parseTags(from: "swift, ai tools, swift, code review")
        #expect(parsed == ["swift", "ai tools", "code review"])

        let snippet = SnippetItem(tags: ["swift", "ai tools"])
        #expect(snippet.tagsText == "swift, ai tools")
    }

    @Test("Saving duplicate snippet updates content fields but keeps organization")
    @MainActor func saveDuplicateSnippetUpdatesExistingSnippet() throws {
        let container = try ModelContainer(
            for: ClipItem.self, SnippetItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        let existing = SnippetItem(
            title: "Old title",
            content: "same body",
            contentType: .text,
            groupName: "Keep Group",
            tags: ["swift", "review"],
            isPinned: true,
            createdAt: Date(timeIntervalSince1970: 10),
            lastUsedAt: Date(timeIntervalSince1970: 20),
            usageCount: 7,
            richTextData: Data("old".utf8),
            richTextType: "html"
        )
        context.insert(existing)
        try context.save()

        let clip = ClipItem(content: "same body", contentType: .code, richTextData: Data("new".utf8), richTextType: "rtf")
        clip.displayTitle = "New title"
        clip.groupName = "New Group"

        let saved = SnippetLibrary.saveSnippet(from: clip, title: "Preferred title", in: context) { _ in .updateExisting }
        #expect(saved?.persistentModelID == existing.persistentModelID)
        #expect(existing.title == "Preferred title")
        #expect(existing.contentType == .code)
        #expect(existing.richTextData == Data("new".utf8))
        #expect(existing.richTextType == "rtf")
        #expect(existing.groupName == "Keep Group")
        #expect(existing.tags == ["swift", "review"])
        #expect(existing.isPinned)
        #expect(existing.usageCount == 7)
        #expect(existing.lastUsedAt == Date(timeIntervalSince1970: 20))
    }

    @Test("Snippet search matches plain text across snippet fields")
    @MainActor func snippetSearchMatchesPlainTextAcrossFields() throws {
        let container = try ModelContainer(
            for: ClipItem.self, SnippetItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        context.insert(SnippetItem(title: "Pinned SQL", content: "select id from tasks", contentType: .code, groupName: "Work", tags: ["sql"], isPinned: true))
        context.insert(SnippetItem(title: "Unpinned SQL", content: "select name from users", contentType: .code, groupName: "Work", tags: ["sql"], isPinned: false))
        context.insert(SnippetItem(title: "Pinned Note", content: "remember this", contentType: .text, groupName: "Work", tags: ["sql"], isPinned: true))
        try context.save()

        let store = SnippetStore()
        store.configure(modelContext: context)
        store.searchText = "sql work select"

        #expect(store.items.map(\.resolvedTitle) == ["Pinned SQL", "Unpinned SQL"])
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

    @Test("History sort mode returns the matching clip date")
    @MainActor func historySortModeUsesExpectedDate() {
        let created = Date(timeIntervalSince1970: 100)
        let lastUsed = Date(timeIntervalSince1970: 200)
        let item = ClipItem(content: "hello", createdAt: created, lastUsedAt: lastUsed)

        #expect(HistorySortMode.created.date(for: item) == created)
        #expect(HistorySortMode.lastUsed.date(for: item) == lastUsed)
    }

    @Test("Time grouping follows created time when requested")
    @MainActor func groupItemsByCreatedDate() {
        let now = Date()
        let item = ClipItem(
            content: "hello",
            createdAt: Calendar.current.date(byAdding: .day, value: -2, to: now)!,
            lastUsedAt: now
        )

        let groups = groupItemsByTime([item], sortMode: .created)
        #expect(groups.count == 1)
        #expect(groups.first?.group == .thisWeek)
    }

    @Test("Time grouping follows last used time when requested")
    @MainActor func groupItemsByLastUsedDate() {
        let now = Date()
        let item = ClipItem(
            content: "hello",
            createdAt: Calendar.current.date(byAdding: .day, value: -40, to: now)!,
            lastUsedAt: now
        )

        let groups = groupItemsByTime([item], sortMode: .lastUsed)
        #expect(groups.count == 1)
        #expect(groups.first?.group == .today)
    }

    @Test("Updating last used date moves item to top when sorted by last used")
    @MainActor func updatingLastUsedMovesItemToTop() throws {
        let olderDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        let latestDate = Date(timeIntervalSince1970: 300)

        let olderItem = ClipItem(content: "older", createdAt: olderDate, lastUsedAt: olderDate)
        let newerItem = ClipItem(content: "newer", createdAt: newerDate, lastUsedAt: newerDate)

        let initial = [olderItem, newerItem].sorted { $0.lastUsedAt > $1.lastUsedAt }
        #expect(initial.map(\.content) == ["newer", "older"])

        olderItem.lastUsedAt = latestDate

        let updated = [olderItem, newerItem].sorted { $0.lastUsedAt > $1.lastUsedAt }
        #expect(updated.map(\.content) == ["older", "newer"])
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

    @Test("Enqueue clip items preserves image and file relay kinds")
    @MainActor func enqueueClipItemsPreservesRelayKinds() {
        let manager = makeManager()
        let image = ClipItem(content: "[Image]", contentType: .image, imageData: Data([0x89]))
        let file = ClipItem(content: "/tmp/report.pdf", contentType: .document)
        let text = ClipItem(content: "echo hello", contentType: .text)

        manager.enqueue(clipItems: [image, file, text])

        #expect(manager.items.count == 3)
        #expect(manager.items[0].contentKind == .image)
        #expect(manager.items[0].imageData == Data([0x89]))
        #expect(manager.items[1].contentKind == .file)
        #expect(manager.items[1].displayName == "report.pdf")
        #expect(manager.items[2].contentKind == .text)
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
