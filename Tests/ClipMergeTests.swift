import AppKit
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import Testing
@testable import PasteMemo

@Suite("Merge clips", .serialized)
@MainActor
struct ClipMergeTests {
    private func makeContext() throws -> (ModelContext, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: Schema([ClipItem.self, AutomationRule.self, SmartGroup.self]),
            configurations: [ModelConfiguration(url: root.appendingPathComponent("PasteMemo.store"))]
        )
        return (ModelContext(container), root)
    }

    @Test("texts join in display order — top row first, whatever the copy times; the originals are gone")
    func mergeTexts() throws {
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let top = ClipItem(content: "top", createdAt: now)
        let below = ClipItem(content: "below", contentType: .link, createdAt: now.addingTimeInterval(-60))
        [top, below].forEach(context.insert)
        try context.save()

        let merged = try #require(ClipMerge.merge([top, below], in: context))
        #expect(merged.content == "top\nbelow")
        #expect(merged.contentType == .text)
        #expect(!merged.isSensitive)
        let remaining = try context.fetch(FetchDescriptor<ClipItem>())
        #expect(remaining.map(\.content) == ["top\nbelow"])
    }

    @Test("merging a sensitive clip keeps the result sensitive")
    func keepsSensitive() throws {
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = ClipItem(content: "secret")
        let note = ClipItem(content: "note")
        [secret, note].forEach(context.insert)
        ActionExecutor.applyMetadata([.markSensitive], to: secret, context: context)
        try context.save()

        let merged = try #require(ClipMerge.merge([secret, note], in: context))
        #expect(merged.isSensitive)
    }

    @Test("not offered for a single clip or text mixed with an image")
    func notMergeable() {
        #expect(!ClipMerge.canMerge([ClipItem(content: "a")]))
        #expect(!ClipMerge.canMerge([ClipItem(content: "a"), ClipItem(content: "[Image]", contentType: .image)]))
        // A raw image whose bytes are gone has nothing to merge.
        #expect(!ClipMerge.canMerge([
            ClipItem(content: "[Image]", contentType: .image),
            ClipItem(content: "/x/a.pdf", contentType: .document),
        ]))
    }

    private func imageData(_ type: UTType) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, rep.cgImage!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    @Test("images and files merge in display order into one multi-file clip; raw images get files of their own")
    func mergeFiles() throws {
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let mergedDir = root.appendingPathComponent("Merged")
        try FileManager.default.createDirectory(at: mergedDir, withIntermediateDirectories: true)
        let cached = root.appendingPathComponent("cached.heic")
        try imageData(.heic).write(to: cached)
        let userPhoto = root.appendingPathComponent("photo.jpg")
        try imageData(.jpeg).write(to: userPhoto)

        let now = Date()
        let screenshot = ClipItem(content: "[Image]", contentType: .image,
                                  originalImageFilePath: cached.path, createdAt: now.addingTimeInterval(-60))
        let legacy = ClipItem(content: "[Image]", contentType: .image,
                              imageData: imageData(.png), createdAt: now.addingTimeInterval(-30))
        let finderCopy = ClipItem(content: userPhoto.path, contentType: .image, createdAt: now)
        [finderCopy, legacy, screenshot].forEach(context.insert)
        try context.save()

        let merged = try #require(ClipMerge.mergeFiles([screenshot, legacy, finderCopy], in: context, directory: mergedDir))
        let paths = merged.content.components(separatedBy: "\n")
        #expect(paths.count == 3)
        #expect(paths[0].hasPrefix(mergedDir.path + "/") && paths[0].hasSuffix("/Image 1.heic"))
        #expect(paths[1].hasSuffix("/Image 2.png"))
        #expect(paths[2] == userPhoto.path)
        #expect(paths.allSatisfy(FileManager.default.fileExists))
        #expect(merged.contentType == .image)
        #expect(merged.imageData != nil)
        #expect(try context.fetch(FetchDescriptor<ClipItem>()).count == 1)
    }

    @Test("an image next to a document makes a generic file clip")
    func mixedFiles() throws {
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let items = [
            ClipItem(content: "/x/a.jpg", contentType: .image),
            ClipItem(content: "/x/b.pdf", contentType: .document),
        ]
        items.forEach(context.insert)
        let merged = try #require(ClipMerge.mergeFiles(items, in: context, directory: root))
        #expect(merged.contentType == .file)
        #expect(merged.content.components(separatedBy: "\n").count == 2)
    }

    @Test("merge folders no clip points into are orphans")
    func orphans() throws {
        let (context, root) = try makeContext()
        defer { try? FileManager.default.removeItem(at: root) }
        let mergedDir = root.appendingPathComponent("Merged")
        let kept = mergedDir.appendingPathComponent("kept")
        let orphan = mergedDir.appendingPathComponent("orphan")
        for folder in [kept, orphan] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        context.insert(ClipItem(content: "/Users/me/a.pdf\n" + kept.appendingPathComponent("Image 1.png").path, contentType: .file))
        try context.save()

        let orphans = ClipMerge.orphanedMergeFolders(in: context, directory: mergedDir)
        #expect(orphans.map(\.lastPathComponent) == ["orphan"])
    }
}
