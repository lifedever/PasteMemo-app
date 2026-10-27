import Foundation
import ImageIO

/// Grid thumbnails for the storage pages, decoded off the main thread straight from the store.
/// A clip from before the original/thumbnail split keeps its full-size image in `imageData`
/// (15–17 MB ones aren't rare), and faulting that on the main thread for every cell froze the
/// grid. Here the blob is read through a read-only SQLite connection — an external blob is
/// decoded from its file, streamed by ImageIO — and only a few decodes run at once, so a fast
/// scroll can't pile up dozens of full-size bitmaps.
actor StorageThumbnailLoader {
    static let shared = StorageThumbnailLoader()

    private static let MAX_CONCURRENT = 3
    private let cache = NSCache<NSString, CGImage>()
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private init() {
        cache.countLimit = 300
    }

    /// `version` changes when the clip's thumbnail does (its stored size, from the scan), so an
    /// edited file re-copied in the meantime doesn't keep showing its old picture.
    func thumbnail(itemID: String, version: Int64, maxPixel: Int) async -> CGImage? {
        let key = "\(itemID)|\(version)|\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        await acquire()
        defer { release() }
        // Scrolled away while queued: nobody will see it.
        guard !Task.isCancelled else { return nil }
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .utility) {
            Self.decode(itemID: itemID, maxPixel: maxPixel)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private func acquire() async {
        if running < Self.MAX_CONCURRENT {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    /// Core Data frames the blob: 0x01 + the bytes inline, or 0x02 + the UUID of a file in
    /// `_EXTERNAL_DATA` (see `StorageScanner`).
    nonisolated static func decode(itemID: String, maxPixel: Int, store: URL = StorageScanner.Locations.liveStore) -> CGImage? {
        let locations = StorageScanner.Locations(store: store, originals: URL(fileURLWithPath: "/"), backups: nil)
        guard let db = SQLiteConnection(path: locations.store.path, readOnly: true) else { return nil }
        defer { db.close() }
        db.setBusyTimeout(milliseconds: 2000)
        var blob: Data?
        db.forEachRow("SELECT ZIMAGEDATA FROM ZCLIPITEM WHERE ZITEMID = ? LIMIT 1", params: [itemID]) {
            blob = $0.blob(0)
        }
        guard let blob, let marker = blob.first else { return nil }

        let source: CGImageSource?
        switch marker {
        case 0x02 where blob.count >= 37:
            guard let name = String(data: blob.subdata(in: 1..<37), encoding: .ascii) else { return nil }
            source = CGImageSourceCreateWithURL(locations.externalData.appendingPathComponent(name) as CFURL, nil)
        case 0x01:
            source = CGImageSourceCreateWithData(blob.dropFirst() as CFData, nil)
        default:
            source = CGImageSourceCreateWithData(blob as CFData, nil)
        }
        guard let source else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
