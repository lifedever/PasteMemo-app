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

    @Test("Finder .file ClipItem becomes .file kind (not rejected)")
    @MainActor func fileBecomesFileKind() {
        let clip = ClipItem(content: "/tmp/foo.txt", contentType: .file)
        let item = RelayItem.from(clip)
        #expect(item?.contentKind == .file)
        #expect(item?.content == "/tmp/foo.txt")
        #expect(item?.imageData == nil)
    }

    @Test("empty .file ClipItem is rejected")
    @MainActor func rejectsEmptyFile() {
        let clip = ClipItem(content: "   ", contentType: .file)
        #expect(RelayItem.from(clip) == nil)
    }

    @Test("image ClipItem with file path becomes .file kind")
    @MainActor func imageWithPathBecomesFile() {
        let data = Data([0x89, 0x50])
        let clip = ClipItem(
            content: "/Users/me/Downloads/photo.png",
            contentType: .image,
            imageData: data
        )
        let item = RelayItem.from(clip)
        #expect(item?.contentKind == .file)
        #expect(item?.content == "/Users/me/Downloads/photo.png")
        #expect(item?.imageData == data)
    }

    @Test("empty-text ClipItem is rejected")
    @MainActor func rejectsEmpty() {
        let clip = ClipItem(content: "   \n  ", contentType: .text)
        #expect(RelayItem.from(clip) == nil)
    }
}

@Suite("RelayQueuePersistence round-trip")
struct RelayQueuePersistenceTests {

    @Test("encodes and decodes full RelayItem fields")
    func roundTrip() throws {
        let snapshot = Data("snap".utf8)
        let image = Data([0x89, 0x50])
        let persisted = PersistedRelayItem(
            id: UUID(),
            content: "hello",
            imageData: image,
            contentKind: "image",
            pasteboardSnapshot: snapshot,
            state: "pending"
        )
        let encoded = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedRelayItem.self, from: encoded)
        #expect(decoded.id == persisted.id)
        #expect(decoded.content == "hello")
        #expect(decoded.imageData == image)
        #expect(decoded.contentKind == "image")
        #expect(decoded.pasteboardSnapshot == snapshot)
    }

    @Test("decodes legacy file missing new fields as nil")
    func legacyCompat() throws {
        let legacyJSON = Data(#"""
        {"id":"7DEFEFFD-DBF8-4B9E-9A6E-0C00000000AA","content":"legacy","state":"pending"}
        """#.utf8)
        let decoded = try JSONDecoder().decode(PersistedRelayItem.self, from: legacyJSON)
        #expect(decoded.content == "legacy")
        #expect(decoded.imageData == nil)
        #expect(decoded.contentKind == nil)
        #expect(decoded.pasteboardSnapshot == nil)
    }
}
