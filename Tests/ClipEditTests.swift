import Foundation
import SwiftData
import Testing
@testable import PasteMemo

@Suite("Edit clip text", .serialized)
@MainActor
struct ClipEditTests {
    private func makeContext() throws -> (ModelContext, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: Schema([ClipItem.self, AutomationRule.self, SmartGroup.self]),
            configurations: [ModelConfiguration(url: root.appendingPathComponent("PasteMemo.store"))]
        )
        return (ModelContext(container), root)
    }

    private var manager: ClipboardManager { ClipboardManager.shared }

    @Test("editing a rich clip drops rich text AND the pasteboard snapshot — paste replays the snapshot verbatim")
    func dropsSnapshot() throws {
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = ClipItem(
            content: "Hello Tom",
            richTextData: Data("{\\rtf1 Hello Tom}".utf8),
            richTextType: "rtf",
            pasteboardSnapshot: Data([1, 2, 3])
        )
        context.insert(item)
        try context.save()

        #expect(manager.applyEditedContent("Hello Jerry", to: item, context: context))
        #expect(item.content == "Hello Jerry")
        #expect(item.displayTitle == "Hello Jerry")
        #expect(item.richTextData == nil)
        #expect(item.richTextType == nil)
        #expect(item.pasteboardSnapshot == nil)
    }

    @Test("unchanged or emptied text is a no-op and keeps the formatting")
    func noOp() throws {
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = ClipItem(content: "same", richTextData: Data("rtf".utf8), richTextType: "rtf", pasteboardSnapshot: Data([1]))
        context.insert(item)
        try context.save()

        #expect(!manager.applyEditedContent("same", to: item, context: context))
        #expect(!manager.applyEditedContent("", to: item, context: context))
        #expect(item.content == "same")
        #expect(item.richTextData != nil)
        #expect(item.pasteboardSnapshot != nil)
    }

    @Test("text and code don't flip into each other; a code clip keeps its language")
    func textCodeStable() throws {
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = ClipItem(content: "note")
        let code = ClipItem(content: "let a = 1", contentType: .code, codeLanguage: "swift")
        [text, code].forEach(context.insert)
        try context.save()

        manager.applyEditedContent("func main() {\n    let x = 1\n    print(x)\n}", to: text, context: context)
        #expect(text.contentType == .text)

        manager.applyEditedContent("hello there", to: code, context: context)
        #expect(code.contentType == .code)
        #expect(code.codeLanguage == "swift")
    }

    @Test("a link edited into a sentence becomes text and loses the old page title / favicon")
    func linkToText() throws {
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = ClipItem(content: "https://example.com/a?id=1", contentType: .link)
        link.linkTitle = "Example"
        link.faviconData = Data([9])
        context.insert(link)
        try context.save()

        manager.applyEditedContent("see the example page", to: link, context: context)
        #expect(link.contentType == .text)
        #expect(link.linkTitle == nil)
        #expect(link.faviconData == nil)
    }

    @Test("text edited into a URL becomes a link")
    func textToLink() throws {
        // 离线模式挡住改成链接后的网页标题抓取，测试里不发网络请求
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "offlineModeEnabled")
        defaults.set(true, forKey: "offlineModeEnabled")
        defer { defaults.set(previous, forKey: "offlineModeEnabled") }

        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = ClipItem(content: "draft")
        context.insert(item)
        try context.save()

        manager.applyEditedContent("https://example.com/b?id=2", to: item, context: context)
        #expect(item.contentType == .link)
    }

    @Test("text edited into an existing file path stays text — pasting it shouldn't turn into a file")
    func pathStaysText() throws {
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = ClipItem(content: "draft")
        context.insert(item)
        try context.save()

        manager.applyEditedContent(root.path, to: item, context: context)
        #expect(item.contentType == .text)
    }

    @Test("a clip marked sensitive stays sensitive after an edit")
    func keepsSensitive() throws {
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = ClipItem(content: "my note")
        context.insert(item)
        ActionExecutor.applyMetadata([.markSensitive], to: item, context: context)
        try context.save()

        manager.applyEditedContent("my note, fixed", to: item, context: context)
        #expect(item.isSensitive)
    }

    @Test("only plain-string clips are editable; data-URI images and files aren't")
    func editableTypes() throws {
        #expect(ClipItem(content: "a").isEditableText == false) // not inserted → no context → gone
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = ClipItem(content: "a")
        let link = ClipItem(content: "https://example.com", contentType: .link)
        let color = ClipItem(content: "#ff0000", contentType: .color)
        let dataURI = ClipItem(content: "data:image/png;base64,iVBORw0KGgo=", contentType: .link)
        let image = ClipItem(content: "[Image]", contentType: .image)
        let file = ClipItem(content: "/tmp/a.txt", contentType: .file)
        [text, link, color, dataURI, image, file].forEach(context.insert)

        #expect(text.isEditableText)
        #expect(link.isEditableText)
        #expect(color.isEditableText)
        #expect(!dataURI.isEditableText)
        #expect(!image.isEditableText)
        #expect(!file.isEditableText)
    }
}
