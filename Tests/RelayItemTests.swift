import Foundation
import Testing
@testable import PasteMemo

@Suite("RelayItem factory")
struct RelayItemTests {

    @Test("Init sets pending state")
    func initState() {
        let item = RelayItem(content: "test")
        #expect(item.state == .pending)
        #expect(item.content == "test")
        #expect(!item.id.uuidString.isEmpty)
    }

    @Test("from plain-text ClipItem")
    @MainActor func fromPlainText() {
        let clip = ClipItem(content: "hello", contentType: .text)
        let item = RelayItem.from(clip)
        #expect(item?.content == "hello")
        #expect(item?.contentKind == .text)
        #expect(item?.imageData == nil)
        #expect(item?.pasteboardSnapshot == nil)
    }

    @Test("from image-only ClipItem")
    @MainActor func fromImage() {
        let data = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes, just a marker
        let clip = ClipItem(content: "[Image]", contentType: .image, imageData: data)
        let item = RelayItem.from(clip)
        #expect(item?.contentKind == .image)
        #expect(item?.imageData == data)
    }

    @Test("from rich-text ClipItem carries snapshot")
    @MainActor func fromRichText() {
        let snapshot = Data("snapshot-bytes".utf8)
        let clip = ClipItem(
            content: "rich",
            contentType: .text,
            richTextData: Data("<html/>".utf8),
            richTextType: "html",
            pasteboardSnapshot: snapshot
        )
        let item = RelayItem.from(clip)
        #expect(item?.contentKind == .text)
        #expect(item?.content == "rich")
        #expect(item?.pasteboardSnapshot == snapshot)
    }

    @Test("Finder .file ClipItem is rejected")
    @MainActor func rejectsFile() {
        let clip = ClipItem(content: "/tmp/foo.txt", contentType: .file)
        #expect(RelayItem.from(clip) == nil)
    }

    @Test("empty-text ClipItem is rejected")
    @MainActor func rejectsEmpty() {
        let clip = ClipItem(content: "   \n  ", contentType: .text)
        #expect(RelayItem.from(clip) == nil)
    }
}
