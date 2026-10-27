import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import PasteMemo

@Suite("StorageThumbnailLoader.decode")
@MainActor
struct StorageThumbnailLoaderTests {
    private func png(width: Int, height: Int, noise: Bool) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        if noise, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            // Incompressible, so the PNG is large enough for Core Data's external storage.
            for i in 0..<(context.bytesPerRow * height) { pixels[i] = UInt8.random(in: 0...255) }
        } else {
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let image = try #require(context.makeImage())
        let buffer = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    @Test("Decodes inline and external-file blobs, capped at the requested size; unknown IDs give nil")
    func decodesBothStorageForms() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbLoader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("PasteMemo.store")
        let container = try ModelContainer(
            for: Schema([ClipItem.self, AutomationRule.self, SmartGroup.self]),
            configurations: [ModelConfiguration(url: store)]
        )
        let small = ClipItem(content: "[Image]", contentType: .image, imageData: try png(width: 64, height: 32, noise: false))
        let large = ClipItem(content: "[Image]", contentType: .image, imageData: try png(width: 900, height: 600, noise: true))
        container.mainContext.insert(small)
        container.mainContext.insert(large)
        try container.mainContext.save()

        let externalFiles = try FileManager.default.contentsOfDirectory(atPath: StorageScanner.Locations(
            store: store, originals: root, backups: nil
        ).externalData.path)
        #expect(!externalFiles.isEmpty, "the large image should live in _EXTERNAL_DATA")

        let inline = try #require(StorageThumbnailLoader.decode(itemID: small.itemID, maxPixel: 280, store: store))
        #expect(inline.width == 64 && inline.height == 32)
        let external = try #require(StorageThumbnailLoader.decode(itemID: large.itemID, maxPixel: 280, store: store))
        #expect(max(external.width, external.height) == 280)
        #expect(StorageThumbnailLoader.decode(itemID: "no-such-id", maxPixel: 280, store: store) == nil)
    }
}
