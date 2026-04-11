import AppKit
import AVFoundation
import ImageIO

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private var previewTasks: [String: Task<Void, Never>] = [:]
    private var thumbnailTasks: [String: Task<Void, Never>] = [:]
    private var videoThumbnailTasks: [String: Task<Void, Never>] = [:]
    private var videoDurations: [String: String] = [:]
    private let taskQueue = DispatchQueue(label: "ImageCache.tasks")
    private let videoMetadataQueue = DispatchQueue(label: "ImageCache.videoMetadata")

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    func thumbnail(for data: Data, key: String, size: CGFloat = 36) -> NSImage? {
        let cacheKey = thumbnailCacheKey(for: key, size: size)
        if let cached = cache.object(forKey: cacheKey) { return cached }

        guard let source = downsample(data: data, maxPixelSize: size * 2) ?? NSImage(data: data) else { return nil }
        let thumb = resize(source, to: size)
        cache.setObject(thumb, forKey: cacheKey, cost: data.count)
        return thumb
    }

    func cachedThumbnail(for key: String, size: CGFloat) -> NSImage? {
        cache.object(forKey: thumbnailCacheKey(for: key, size: size))
    }

    func cachedPreview(for key: String, maxDimension: CGFloat) -> NSImage? {
        cache.object(forKey: previewCacheKey(for: key, maxDimension: maxDimension))
    }

    func preview(for data: Data, key: String, maxDimension: CGFloat) -> NSImage? {
        let cacheKey = previewCacheKey(for: key, maxDimension: maxDimension)
        if let cached = cache.object(forKey: cacheKey) { return cached }

        guard let image = downsample(data: data, maxPixelSize: maxDimension * 2) ?? NSImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: cacheKey, cost: data.count)
        return image
    }

    func previewTask(for data: Data, key: String, maxDimension: CGFloat) -> Task<Void, Never> {
        let cacheKey = previewCacheKey(for: key, maxDimension: maxDimension)
        let taskKey = cacheKey as String
        if cache.object(forKey: cacheKey) != nil { return Task {} }

        if let existing = existingTask(for: taskKey, in: \.previewTasks) {
            return existing
        }

        let task = Task<Void, Never> { @Sendable [weak self] in
            guard let self else { return }
            _ = self.preview(for: data, key: key, maxDimension: maxDimension)
            self.removeTask(for: taskKey, from: \.previewTasks)
        }

        storeTask(task, for: taskKey, in: \.previewTasks)
        return task
    }

    func thumbnailTask(for data: Data, key: String, size: CGFloat) -> Task<Void, Never> {
        let cacheKey = thumbnailCacheKey(for: key, size: size)
        let taskKey = cacheKey as String
        if cache.object(forKey: cacheKey) != nil { return Task {} }

        if let existing = existingTask(for: taskKey, in: \.thumbnailTasks) {
            return existing
        }

        let task = Task<Void, Never> { @Sendable [weak self] in
            guard let self else { return }
            _ = self.thumbnail(for: data, key: key, size: size)
            self.removeTask(for: taskKey, from: \.thumbnailTasks)
        }

        storeTask(task, for: taskKey, in: \.thumbnailTasks)
        return task
    }

    func cachedVideoDuration(forPath path: String) -> String? {
        videoMetadataQueue.sync {
            videoDurations[path]
        }
    }

    func videoThumbnailTask(forPath path: String) -> Task<Void, Never> {
        if videoThumbnail(forPath: path) != nil, cachedVideoDuration(forPath: path) != nil {
            return Task {}
        }

        if let existing = existingTask(for: path, in: \.videoThumbnailTasks) {
            return existing
        }

        let task = Task<Void, Never> { @Sendable [weak self, path] in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: path) else {
                self.removeTask(for: path, from: \.videoThumbnailTasks)
                return
            }

            let url = URL(fileURLWithPath: path)
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 800)

            if let result = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
                let cgImage = result.image
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                self.setVideoThumbnail(image, forPath: path)
            }

            if let seconds = try? await CMTimeGetSeconds(asset.load(.duration)) {
                self.setVideoDuration(Self.formatDuration(seconds), forPath: path)
            }

            self.removeTask(for: path, from: \.videoThumbnailTasks)
        }

        storeTask(task, for: path, in: \.videoThumbnailTasks)
        return task
    }

    private func setVideoDuration(_ duration: String, forPath path: String) {
        videoMetadataQueue.sync {
            videoDurations[path] = duration
        }
    }

    private func existingTask(
        for key: String,
        in keyPath: KeyPath<ImageCache, [String: Task<Void, Never>]>
    ) -> Task<Void, Never>? {
        taskQueue.sync {
            self[keyPath: keyPath][key]
        }
    }

    private func storeTask(
        _ task: Task<Void, Never>,
        for key: String,
        in keyPath: ReferenceWritableKeyPath<ImageCache, [String: Task<Void, Never>]>
    ) {
        taskQueue.sync {
            self[keyPath: keyPath][key] = task
        }
    }

    private func removeTask(
        for key: String,
        from keyPath: ReferenceWritableKeyPath<ImageCache, [String: Task<Void, Never>]>
    ) {
        _ = taskQueue.sync {
            self[keyPath: keyPath].removeValue(forKey: key)
        }
    }

    func imageDimensions(for data: Data) -> NSSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        return NSSize(width: width, height: height)
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

    private func previewCacheKey(for key: String, maxDimension: CGFloat) -> NSString {
        "preview_\(key)_\(Int(maxDimension))" as NSString
    }

    private func thumbnailCacheKey(for key: String, size: CGFloat) -> NSString {
        "thumb_\(key)_\(Int(size))" as NSString
    }

    private static func formatDuration(_ seconds: Float64) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func downsample(data: Data, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up)))
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
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
