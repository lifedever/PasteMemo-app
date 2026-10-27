import Foundation
import SwiftData
import Testing
@testable import PasteMemo

@Suite("ExportItemSplitter")
struct ExportItemSplitterTests {
    /// Feeds `json` in pieces of the given sizes (cycled) and collects the items.
    private func split(_ json: String, chunkSizes: [Int]) -> (items: [String], skeleton: String, complete: Bool) {
        let bytes = Data(json.utf8)
        var splitter = ExportItemSplitter()
        var items: [String] = []
        var offset = 0
        var turn = 0
        while offset < bytes.count {
            let size = chunkSizes[turn % chunkSizes.count]
            let end = min(offset + size, bytes.count)
            splitter.feed(bytes.subdata(in: offset..<end)) { items.append(String(decoding: $0, as: UTF8.self)) }
            offset = end
            turn += 1
        }
        return (items, String(decoding: splitter.skeleton, as: UTF8.self), splitter.isComplete)
    }

    private let tricky = #"""
    {"version":2,"note":"items: [ not this ]","items":[{"content":"a } ] { [ \" \\","nested":{"x":[1,{"y":"}"}]}},
     {"content":"items"} ,{"content":"{"}],"exportDate":"2026-10-26T00:00:00Z","groups":[{"name":"g"}],"rules":[]}
    """#

    @Test("Strings with braces, escapes and the word items don't confuse it; any chunking gives the same result",
          arguments: [[1], [2, 3], [7], [64], [100_000], [1, 5, 13, 2]])
    func trickyStrings(chunkSizes: [Int]) throws {
        let result = split(tricky, chunkSizes: chunkSizes)
        #expect(result.complete)
        #expect(result.items.count == 3)
        #expect(result.items[0].hasPrefix(#"{"content":"a } ] { [ \" \\""#))
        #expect(result.items[0].hasSuffix(#""}"}]}}"#))
        #expect(result.items[1] == #"{"content":"items"}"#)
        let skeleton = try JSONSerialization.jsonObject(with: Data(result.skeleton.utf8)) as? [String: Any]
        #expect((skeleton?["items"] as? [Any])?.isEmpty == true)
        #expect(skeleton?["note"] as? String == "items: [ not this ]")
        #expect((skeleton?["groups"] as? [[String: Any]])?.first?["name"] as? String == "g")
    }

    @Test("Each item decodes on its own, and items may come last")
    func itemsLast() throws {
        let json = #"{"rules":[],"groups":[],"exportDate":"2026-10-26T00:00:00Z","version":2,"items":[{"a":1},{"a":2}]}"#
        let result = split(json, chunkSizes: [3])
        #expect(result.items == [#"{"a":1}"#, #"{"a":2}"#])
        #expect(result.complete)
    }

    @Test("Empty items array and a truncated document")
    func emptyAndTruncated() {
        let empty = split(#"{"version":2,"items":[],"groups":[]}"#, chunkSizes: [4])
        #expect(empty.items.isEmpty && empty.complete && empty.skeleton.contains(#""items":[]"#))
        let truncated = split(#"{"version":2,"items":[{"a":"b"},{"a":"#, chunkSizes: [5])
        #expect(truncated.items.count == 1 && !truncated.complete)
    }
}

@Suite("DataPorter streaming import / export", .serialized)
@MainActor
struct DataPorterStreamingTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: ClipItem.self, SmartGroup.self, AutomationRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeSource(originalBytes: Data) throws -> (ModelContainer, URL) {
        let source = try container()
        let context = source.mainContext
        let originalURL = FileManager.default.temporaryDirectory.appendingPathComponent("streaming-original-\(UUID().uuidString).png")
        try originalBytes.write(to: originalURL)
        let screenshot = ClipItem(content: "[Image]", contentType: .image, imageData: Data([1, 2, 3]),
                                  originalImageFilePath: originalURL.path, sourceApp: "微信")
        screenshot.displayTitle = "Image (10×10)"
        context.insert(screenshot)
        context.insert(ClipItem(content: "有 } 和 \" 的文本", contentType: .text, sourceApp: nil))
        let group = SmartGroup(name: "工作")
        context.insert(group)
        try context.save()
        return (source, originalURL)
    }

    /// The import writes originals into the real cache folder; remove them afterwards.
    private func cleanUpOriginals(in context: ModelContext) throws {
        let paths = try context.fetch(FetchDescriptor<ClipItem>()).compactMap(\.originalImageFilePath)
        StorageCleaner.deleteCachedOriginals(paths)
    }

    @Test("Export → import keeps the full-size original, plain and encrypted", arguments: [nil, "secret"])
    func roundTrip(password: String?) async throws {
        let original = Data((0..<50_000).map { UInt8($0 % 251) })
        let (source, originalURL) = try makeSource(originalBytes: original)
        defer { try? FileManager.default.removeItem(at: originalURL) }
        let context = source.mainContext
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("streaming-\(UUID().uuidString).pastememo")
        defer { try? FileManager.default.removeItem(at: file) }

        try await DataPorter.writeExportFile(
            clipItems: try context.fetch(FetchDescriptor<ClipItem>()),
            groups: try context.fetch(FetchDescriptor<SmartGroup>()),
            rules: [], to: file, password: password
        )
        let fileData = try Data(contentsOf: file)
        #expect(DataPorterCrypto.isEncrypted(fileData) == (password != nil))

        let dest = try container()
        let body = try DataPorterCrypto.decrypt(fileData: fileData, password: password ?? "")
        let result = try await DataPorter.importStreaming(body, into: dest.mainContext)
        defer { try? cleanUpOriginals(in: dest.mainContext) }

        #expect(result.imported == 2 && result.importedGroups == 1)
        let restored = try dest.mainContext.fetch(FetchDescriptor<ClipItem>(predicate: #Predicate { $0.content == "[Image]" }))
        let restoredPath = try #require(restored.first?.originalImageFilePath)
        #expect(restoredPath != originalURL.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: restoredPath)) == original)
        #expect(restored.first?.imageData == Data([1, 2, 3]))
        #expect(restored.first?.displayTitle == "Image (10×10)")

        // Importing the same file again only skips.
        let again = try await DataPorter.importStreaming(body, into: dest.mainContext)
        #expect(again.imported == 0 && again.skipped == 2)
    }

    @Test("Backup layout: envelope written ahead of the stream reads back through decrypt")
    func backupLayout() async throws {
        let (source, originalURL) = try makeSource(originalBytes: Data(repeating: 7, count: 1000))
        defer { try? FileManager.default.removeItem(at: originalURL) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString).pastememo")
        defer { try? FileManager.default.removeItem(at: file) }
        try await DataPorter.encodeAndCompress(
            clipItems: try source.mainContext.fetch(FetchDescriptor<ClipItem>()), groups: [], rules: [],
            to: file, header: DataPorterCrypto.wrapPlaintext(Data())
        )
        let body = try DataPorterCrypto.decrypt(fileData: try Data(contentsOf: file), password: "")
        let dest = try container()
        let result = try await DataPorter.importStreaming(body, into: dest.mainContext)
        defer { try? cleanUpOriginals(in: dest.mainContext) }
        #expect(result.imported == 2)
    }

    @Test("Files from before: in-memory encoder output and plain uncompressed JSON both import")
    func olderFiles() async throws {
        let (source, originalURL) = try makeSource(originalBytes: Data(repeating: 9, count: 100))
        defer { try? FileManager.default.removeItem(at: originalURL) }
        var payload = DataPorter.buildExportPayload(try source.mainContext.fetch(FetchDescriptor<ClipItem>()))
        // As written by a version without originals.
        payload = ExportPayload(
            version: payload.version, exportDate: payload.exportDate,
            items: payload.items.map { var item = $0; item.originalImageBase64 = nil; return item },
            groups: nil, rules: nil
        )
        let compressed = try DataPorter.encodeAndCompress(payload)
        let plainEncoder = JSONEncoder()
        plainEncoder.dateEncodingStrategy = .iso8601
        let plain = try plainEncoder.encode(payload)

        for body in [compressed, plain] {
            let dest = try container()
            let result = try await DataPorter.importStreaming(body, into: dest.mainContext)
            #expect(result.imported == 2)
            let image = try dest.mainContext.fetch(FetchDescriptor<ClipItem>(predicate: #Predicate { $0.content == "[Image]" }))
            #expect(image.first?.originalImageFilePath == nil)
        }
    }

    @Test("Snapshot, file paths, SMS text and AI Agent source survive export → import")
    func previouslyDroppedFields() async throws {
        let source = try container()
        let snapshot = Data("pasteboard replay".utf8)
        let mixed = ClipItem(content: "文字和文件", contentType: .mixed, sourceApp: "访达")
        mixed.filePaths = "/Users/me/a.pdf\n/Users/me/b.png"
        mixed.pasteboardSnapshot = snapshot
        let code = ClipItem(content: "123456", contentType: .text, sourceApp: "信息")
        code.smsMessageText = "【银行】验证码 123456，5 分钟内有效"
        let agent = ClipItem(content: "agent wrote this", contentType: .text, sourceApp: nil)
        agent.agentSource = "claude-code"
        [mixed, code, agent].forEach(source.mainContext.insert)
        try source.mainContext.save()

        let payload = DataPorter.buildExportPayload(try source.mainContext.fetch(FetchDescriptor<ClipItem>()))
        let dest = try container()
        _ = try await DataPorter.importStreaming(try DataPorter.encodeAndCompress(payload), into: dest.mainContext)
        let byContent = Dictionary(uniqueKeysWithValues: try dest.mainContext.fetch(FetchDescriptor<ClipItem>()).map { ($0.content, $0) })

        #expect(byContent["文字和文件"]?.filePaths == "/Users/me/a.pdf\n/Users/me/b.png")
        #expect(byContent["文字和文件"]?.pasteboardSnapshot == snapshot)
        #expect(byContent["123456"]?.smsMessageText == "【银行】验证码 123456，5 分钟内有效")
        #expect(byContent["agent wrote this"]?.agentSource == "claude-code")

        // A file from before these fields existed imports with them empty.
        let old = ExportPayload(
            version: payload.version, exportDate: payload.exportDate,
            items: payload.items.map {
                var item = $0
                item.pasteboardSnapshotBase64 = nil; item.filePaths = nil
                item.smsMessageText = nil; item.agentSource = nil
                return item
            },
            groups: nil, rules: nil
        )
        let fresh = try container()
        let result = try await DataPorter.importStreaming(try DataPorter.encodeAndCompress(old), into: fresh.mainContext)
        #expect(result.imported == 3)
        #expect(try fresh.mainContext.fetch(FetchDescriptor<ClipItem>()).allSatisfy { $0.agentSource == nil && $0.filePaths == nil })
    }

    @Test("A damaged file fails instead of importing half")
    func damaged() async throws {
        let truncated = Data(#"{"version":2,"items":[{"content":"x""#.utf8)
        let dest = try container()
        await #expect(throws: (any Error).self) {
            _ = try await DataPorter.importStreaming(truncated, into: dest.mainContext)
        }
        #expect(try dest.mainContext.fetchCount(FetchDescriptor<ClipItem>()) == 0)
    }
}
