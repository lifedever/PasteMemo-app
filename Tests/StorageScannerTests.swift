import Foundation
import SwiftData
import Testing
@testable import PasteMemo

@Suite("StorageScanner", .serialized)
@MainActor
struct StorageScannerTests {
    private func makeStore() throws -> (container: ModelContainer, locations: StorageScanner.Locations, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScannerTests-\(UUID().uuidString)")
        let originals = root.appendingPathComponent("Originals")
        let backups = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let store = root.appendingPathComponent("PasteMemo.store")
        let schema = Schema([ClipItem.self, AutomationRule.self, SmartGroup.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(url: store)])
        return (container, .init(store: store, originals: originals, backups: backups), root)
    }

    @Test("Sizes come from inline blobs, external blobs and cached originals; flags and sources carry over")
    func scan() throws {
        let (container, locations, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = container.mainContext

        let originalPath = locations.originals.appendingPathComponent("A.tiff").path
        try Data(count: 4_000).write(to: URL(fileURLWithPath: originalPath))
        try Data(count: 1_234).write(to: locations.backups!.appendingPathComponent("PasteMemo-backup-1-x.pastememo"))
        try Data(count: 9_999).write(to: locations.backups!.appendingPathComponent("unrelated.zip"))

        let screenshot = ClipItem(content: "[Image]", contentType: .image, imageData: Data(count: 300),
                                  originalImageFilePath: originalPath, sourceApp: "微信", sourceAppBundleID: "com.tencent.xinWeChat")
        // Large enough for Core Data to move it into _EXTERNAL_DATA.
        let photo = ClipItem(content: "/Users/me/Pictures/a.png", contentType: .image, imageData: Data(count: 600_000),
                             sourceApp: "访达", isPinned: true)
        let note = ClipItem(content: "你好", contentType: .text, sourceApp: nil)
        note.groupName = "收藏夹"
        let group = SmartGroup(name: "收藏夹")
        group.preservesItems = true
        [screenshot, photo, note].forEach(context.insert)
        context.insert(group)
        try context.save()

        let snapshot = try #require(StorageScanner.scan(locations))
        let byID = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })

        let shot = try #require(byID[screenshot.itemID])
        #expect(shot.previewBytes == 300)
        #expect(shot.originalBytes == 4_000)
        #expect(shot.category == .image && shot.sourceName == "微信" && !shot.isProtected)

        let pinned = try #require(byID[photo.itemID])
        #expect(pinned.previewBytes == 600_000)
        #expect(pinned.isProtected)

        let text = try #require(byID[note.itemID])
        #expect(text.textBytes == Int64("你好".utf8.count))
        #expect(text.sourceName == nil && text.isProtected)

        #expect(snapshot.bundleIDs["微信"] == "com.tencent.xinWeChat")
        #expect(snapshot.tiffOriginals.map(\.itemID) == [screenshot.itemID])
        #expect(snapshot.breakdown.originals == 4_000)
        #expect(snapshot.breakdown.previews == 600_300)
        #expect(snapshot.breakdown.backups == 1_234)
        #expect(snapshot.breakdown.textAndIndex > 0)
    }

    @Test("Identical blobs sharing one external file are counted once; rows split it")
    func sharedExternalFile() throws {
        let (container, locations, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let first = ClipItem(content: "[Image]", contentType: .image, imageData: bytes, sourceApp: "Chrome")
        let second = ClipItem(content: "[Image]", contentType: .image, imageData: bytes, sourceApp: "Chrome")
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()

        let snapshot = try #require(StorageScanner.scan(locations))
        let externalOnDisk = StorageScanner.fileSizes(in: locations.externalData).values.reduce(0, +)
        let perRecord = snapshot.records.map(\.previewBytes).reduce(0, +)
        // Whether or not Core Data shared the file here, the totals must match what's on disk.
        #expect(snapshot.breakdown.previews == externalOnDisk)
        #expect(abs(perRecord - snapshot.breakdown.previews) <= 1)
    }

    @Test("A missing store scans as nil instead of an empty snapshot")
    func missingStore() {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        let locations = StorageScanner.Locations(
            store: nowhere.appendingPathComponent("PasteMemo.store"), originals: nowhere, backups: nil
        )
        #expect(StorageScanner.scan(locations) == nil)
    }
}
