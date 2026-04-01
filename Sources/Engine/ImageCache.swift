import AppKit

@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    func thumbnail(for data: Data, key: String, size: CGFloat = 36) -> NSImage? {
        let cacheKey = "\(key)_\(Int(size))" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        guard let source = NSImage(data: data) else { return nil }
        let thumb = resize(source, to: size)
        cache.setObject(thumb, forKey: cacheKey, cost: data.count)
        return thumb
    }

    func favicon(for data: Data, key: String) -> NSImage? {
        let cacheKey = "fav_\(key)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        guard let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: cacheKey, cost: data.count)
        return img
    }

    func fileIcon(forPath path: String) -> NSImage {
        let cacheKey = "file_\(path)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: cacheKey, cost: 1024)
        return icon
    }

    func videoThumbnail(forPath path: String) -> NSImage? {
        let cacheKey = "video_\(path)" as NSString
        return cache.object(forKey: cacheKey)
    }

    func setVideoThumbnail(_ image: NSImage, forPath path: String) {
        let cacheKey = "video_\(path)" as NSString
        cache.setObject(image, forKey: cacheKey, cost: 4096)
    }

    private func resize(_ image: NSImage, to maxDimension: CGFloat) -> NSImage {
        let original = image.size
        guard original.width > 0, original.height > 0 else { return image }
        let scale = min(maxDimension * 2 / original.width, maxDimension * 2 / original.height)
        let targetSize = NSSize(width: original.width * scale, height: original.height * scale)
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: original),
                   operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}
