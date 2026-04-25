import Foundation
import SwiftData
import Testing
import AppKit
@testable import PasteMemo

@Suite("PasteMemo Tests")
struct PasteMemoTests {
    @Test("Detect text content type")
    @MainActor func detectText() {
        let result = ClipboardManager.shared.detectContentType("Hello world")
        #expect(result.type == .text)
    }

    @Test("Third-party pasteboard UTI triggers snapshot capture (issue #29 — Telegram custom emoji)")
    @MainActor func thirdPartyTypesDetected() {
        let pb = NSPasteboard(name: NSPasteboard.Name("pastememo-test-thirdparty-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("🧡", forType: .string)
        pb.setData(Data([0x01, 0x02, 0x03]), forType: NSPasteboard.PasteboardType("com.trolltech.anymime.application--x-td-field-tags"))
        #expect(ClipboardManager.shared.pasteboardHasThirdPartyTypes(pb) == true)
    }

    @Test("Apple-standard UTIs only do not trigger snapshot")
    @MainActor func standardTypesOnlyDoNotTriggerSnapshot() {
        let pb = NSPasteboard(name: NSPasteboard.Name("pastememo-test-standard-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("hello", forType: .string)
        pb.setData(Data([0x68, 0x69]), forType: NSPasteboard.PasteboardType("public.utf16-plain-text"))
        pb.setData(Data([0x01]), forType: NSPasteboard.PasteboardType("com.apple.traditional-mac-plain-text"))
        pb.setData(Data([0x01]), forType: NSPasteboard.PasteboardType("CorePasteboardFlavorType 0x54455854"))
        #expect(ClipboardManager.shared.pasteboardHasThirdPartyTypes(pb) == false)
    }

    @Test("restorePasteboardSnapshot strips Office-private UTIs (issue #28 — Word private clipboard hijack)")
    @MainActor func restoreStripsOfficePrivateTypes() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("pastememo-test-strip-\(UUID().uuidString)"))
        // Old-format snapshot (pre-capture-filter era) still contains Microsoft-private
        // types; restore must drop them so Word paste falls back to public.rtf and
        // doesn't hijack into its internal clipboard cache.
        let snapshotDict: [String: Data] = [
            "public.rtf": Data("rtf-bytes".utf8),
            "public.utf8-plain-text": Data("plain".utf8),
            "com.microsoft.Object-Descriptor": Data([0x01, 0x02]),
            "com.microsoft.DataObject": Data([0x03, 0x04]),
            "com.microsoft.ole.source.68787.0x1047f01d8": Data([0x05]),
        ]
        let blob = try PropertyListSerialization.data(fromPropertyList: snapshotDict, format: .binary, options: 0)
        pb.clearContents()
        let ok = ClipboardManager.shared.restorePasteboardSnapshot(blob, to: pb)
        #expect(ok)
        let restoredTypes = Set((pb.types ?? []).map(\.rawValue))
        #expect(restoredTypes.contains("public.rtf"))
        #expect(restoredTypes.contains("public.utf8-plain-text"))
        #expect(restoredTypes.contains("com.microsoft.Object-Descriptor") == false)
        #expect(restoredTypes.contains("com.microsoft.DataObject") == false)
        #expect(restoredTypes.contains("com.microsoft.ole.source.68787.0x1047f01d8") == false)
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

    @Test("DataPorter v2 round-trips groups and user rules, skipping built-in rules")
    @MainActor func dataPorterRoundTripsGroupsAndRules() throws {
        let sourceContainer = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let sourceContext = sourceContainer.mainContext

        let clip = ClipItem(content: "hello", contentType: .text)
        clip.groupName = "Work"
        sourceContext.insert(clip)

        let group = SmartGroup(name: "Work", icon: "briefcase", sortOrder: 7, color: "#FF0000", preservesItems: true)
        sourceContext.insert(group)

        let userRule = AutomationRule(
            name: "Lowercase links",
            enabled: true,
            isBuiltIn: false,
            triggerMode: .manual,
            conditions: [.contentType(.link)],
            actions: [.lowercased]
        )
        sourceContext.insert(userRule)

        let builtInRule = AutomationRule(
            name: "Clean tracking",
            enabled: true,
            isBuiltIn: true,
            conditions: [.contentType(.link)],
            actions: [.removeQueryParams(patterns: ["utm_source"])]
        )
        sourceContext.insert(builtInRule)
        try sourceContext.save()

        let items = try sourceContext.fetch(FetchDescriptor<ClipItem>())
        let groups = try sourceContext.fetch(FetchDescriptor<SmartGroup>())
        let rules = try sourceContext.fetch(FetchDescriptor<AutomationRule>())
        let payload = DataPorter.buildExportPayload(items, groups: groups, rules: rules)

        #expect(payload.version == 2)
        #expect(payload.groups?.count == 1)
        #expect(payload.rules?.count == 2)

        let data = try DataPorter.encodeAndCompress(payload)

        // Fresh container to import into
        let destContainer = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let destContext = destContainer.mainContext
        let result = try DataPorter.importItems(from: data, into: destContext)

        #expect(result.imported == 1)
        #expect(result.importedGroups == 1)
        #expect(result.importedRules == 1) // built-in skipped

        let importedGroups = try destContext.fetch(FetchDescriptor<SmartGroup>())
        #expect(importedGroups.count == 1)
        #expect(importedGroups.first?.name == "Work")
        #expect(importedGroups.first?.icon == "briefcase")
        #expect(importedGroups.first?.sortOrder == 7)
        #expect(importedGroups.first?.color == "#FF0000")
        #expect(importedGroups.first?.preservesItems == true)

        let importedRules = try destContext.fetch(FetchDescriptor<AutomationRule>())
        #expect(importedRules.count == 1)
        let rule = try #require(importedRules.first)
        #expect(rule.name == "Lowercase links")
        #expect(rule.isBuiltIn == false)
        #expect(rule.triggerMode == .manual)
        #expect(rule.conditions == [.contentType(.link)])
        #expect(rule.actions == [.lowercased])
    }

    @Test("DataPorter v1 payload imports without groups or rules and raises no error")
    @MainActor func dataPorterV1BackwardCompatible() throws {
        let sourceContainer = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let sourceContext = sourceContainer.mainContext
        sourceContext.insert(ClipItem(content: "legacy", contentType: .text))
        try sourceContext.save()

        // Simulate a v1 file: items only, no groups/rules fields.
        let items = try sourceContext.fetch(FetchDescriptor<ClipItem>())
        let v1Payload = ExportPayload(
            version: 1,
            exportDate: Date(),
            items: items.map(DataPorter.buildSingleExportItem),
            groups: nil,
            rules: nil
        )
        let data = try DataPorter.encodeAndCompress(v1Payload)

        let destContainer = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let result = try DataPorter.importItems(from: data, into: destContainer.mainContext)

        #expect(result.imported == 1)
        #expect(result.importedGroups == 0)
        #expect(result.importedRules == 0)
    }

    @Test("DataPorter v2 merge deduplicates groups by name and rules by ruleID")
    @MainActor func dataPorterMergeDeduplicates() throws {
        let container = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext

        // Pre-existing group and rule in destination
        context.insert(SmartGroup(name: "Work", icon: "folder", sortOrder: 0))
        let existingRule = AutomationRule(name: "Existing", isBuiltIn: false)
        context.insert(existingRule)
        try context.save()
        let existingRuleID = existingRule.ruleID

        // Backup payload contains a group with the same name (should be skipped)
        // and a rule with the same ruleID (should be skipped),
        // plus a new group and new rule.
        let incomingGroup1 = ExportGroup(name: "Work", icon: "briefcase", sortOrder: 9, color: nil, preservesItems: true)
        let incomingGroup2 = ExportGroup(name: "Personal", icon: "house", sortOrder: 1, color: nil, preservesItems: true)
        let incomingRule1 = DataPorter.buildSingleExportRule(existingRule) // same ruleID
        let newRule = AutomationRule(name: "Brand new", isBuiltIn: false)
        let incomingRule2 = DataPorter.buildSingleExportRule(newRule)

        let payload = ExportPayload(
            version: 2,
            exportDate: Date(),
            items: [],
            groups: [incomingGroup1, incomingGroup2],
            rules: [incomingRule1, incomingRule2]
        )
        let data = try DataPorter.encodeAndCompress(payload)

        let result = try DataPorter.importItems(from: data, into: context)
        #expect(result.importedGroups == 1) // only Personal added
        #expect(result.importedRules == 1)  // only new rule added

        let allGroups = try context.fetch(FetchDescriptor<SmartGroup>())
        #expect(Set(allGroups.map(\.name)) == ["Work", "Personal"])
        let workGroup = try #require(allGroups.first { $0.name == "Work" })
        #expect(workGroup.icon == "folder") // existing not overwritten
        #expect(workGroup.sortOrder == 0)
        #expect(workGroup.preservesItems == false)
        let personalGroup = try #require(allGroups.first { $0.name == "Personal" })
        #expect(personalGroup.preservesItems == true)

        let allRules = try context.fetch(FetchDescriptor<AutomationRule>())
        #expect(allRules.count == 2)
        #expect(allRules.contains { $0.ruleID == existingRuleID })
        #expect(allRules.contains { $0.name == "Brand new" })
    }

    @Test("DataPorter import rebuilds SmartGroup counts from items (regression for issue #31)")
    @MainActor func dataPorterImportRebuildsGroupCounts() throws {
        // Source: two groups with items, SmartGroup.count deliberately desynced from reality
        let sourceContainer = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let sourceContext = sourceContainer.mainContext
        let work = SmartGroup(name: "Work", icon: "briefcase", sortOrder: 0)
        work.count = 999 // stale value; import must ignore and recompute
        sourceContext.insert(work)
        sourceContext.insert(SmartGroup(name: "Personal", icon: "house", sortOrder: 1))
        for i in 0..<3 {
            let clip = ClipItem(content: "w\(i)", contentType: .text)
            clip.groupName = "Work"
            sourceContext.insert(clip)
        }
        for i in 0..<2 {
            let clip = ClipItem(content: "p\(i)", contentType: .text)
            clip.groupName = "Personal"
            sourceContext.insert(clip)
        }
        sourceContext.insert(ClipItem(content: "ungrouped", contentType: .text))
        try sourceContext.save()

        let items = try sourceContext.fetch(FetchDescriptor<ClipItem>())
        let groups = try sourceContext.fetch(FetchDescriptor<SmartGroup>())
        let payload = DataPorter.buildExportPayload(items, groups: groups, rules: [])
        let data = try DataPorter.encodeAndCompress(payload)

        let destContainer = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let destContext = destContainer.mainContext
        _ = try DataPorter.importItems(from: data, into: destContext)

        let importedGroups = try destContext.fetch(FetchDescriptor<SmartGroup>())
        let workGroup = try #require(importedGroups.first { $0.name == "Work" })
        let personalGroup = try #require(importedGroups.first { $0.name == "Personal" })
        #expect(workGroup.count == 3)
        #expect(personalGroup.count == 2)
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

    @Test("Data image URI helper detects and decodes base64 image payloads")
    func dataImageURIHelperDecodesPayload() throws {
        let png1x1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lQn4NwAAAABJRU5ErkJggg=="
        let uri = "  data:image/png;base64,\(png1x1)"

        #expect(DataImageURI.isDataImageURI(uri))
        #expect(DataImageURI.isBase64DataImageURI(uri))
        let data = try #require(DataImageURI.decodedImageData(from: uri))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("Data image URI helper keeps non-base64 image payloads out of decode path")
    func dataImageURIHelperDistinguishesNonBase64Payloads() {
        let uri = "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%3E%3C/svg%3E"

        #expect(DataImageURI.isDataImageURI(uri))
        #expect(!DataImageURI.isBase64DataImageURI(uri))
        #expect(DataImageURI.decodedImageData(from: uri) == nil)
    }

    @Test("Data image URI helper refuses payloads above decoded byte cap")
    func dataImageURIHelperHonorsDecodedByteCap() {
        let uri = "data:image/png;base64,QUJDRA=="

        #expect(DataImageURI.decodedImageData(from: uri, maxDecodedBytes: 2) == nil)
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

    /// Regression: when the store is inactive (panel/window hidden), observers used to silently drop
    /// save notifications, leaving `needsRefresh` false. The next activation would then skip the
    /// refresh and display stale sort order (e.g. a multi-file paste not bumping to top).
    /// All four observers (throttled + 3 direct) must mark `needsRefresh = true` when inactive.
    @Test("Observers mark needsRefresh when store is inactive", .serialized, arguments: [
        "ClipItemStoreItemDidUpdate",
        "ClipItemStoreItemLastUsedDidUpdate",
        "ClipItemStoreItemContentDidUpdate",
    ])
    @MainActor func inactiveObserversMarkDirty(notificationName: String) async throws {
        let container = try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = ClipItemStore()
        store.configure(modelContext: container.mainContext)
        // configure() consumes the initial dirty flag
        #expect(store.needsRefresh == false)
        // Simulate the panel/window being hidden
        store.isActive = false

        NotificationCenter.default.post(name: Notification.Name(notificationName), object: nil)
        // Combine's .receive(on: RunLoop.main) delivers on the next runloop tick
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.needsRefresh == true, "\(notificationName) should mark dirty when inactive")
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
