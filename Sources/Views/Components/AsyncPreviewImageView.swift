import SwiftUI
import AppKit

struct AsyncPreviewImageView: View {
    let data: Data?
    let cacheKey: String
    var maxPixelSize: CGFloat = 1200
    var cornerRadius: CGFloat = 8
    var thumbnailSize: CGFloat = 240
    var onDoubleClick: (() -> Void)? = nil
    /// `data` 为 nil 时的磁盘兜底源（多图文件条目没有缩略图字节，读第一张原文件）。
    var fallbackFileURL: URL? = nil
    /// 贴边条卡片要铺满裁切（宽度按比例算过但有上下限），其余地方保持等比完整显示。
    var contentMode: ContentMode = .fit

    @State private var image: NSImage?
    @State private var thumbnail: NSImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: contentMode)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else if data != nil || fallbackFileURL != nil {
                placeholder
            } else {
                unavailableState
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleClick?()
        }
        .task(id: taskID) {
            await loadImage()
        }
    }

    private var taskID: String {
        "\(cacheKey)_\(Int(maxPixelSize))_\(data?.count ?? 0)_\(fallbackFileURL?.path ?? "")"
    }

    @MainActor
    private func loadImage() async {
        var resolvedData = data
        if resolvedData == nil, let fileURL = fallbackFileURL {
            // 磁盘读取放后台线程，避免大图卡主线程
            resolvedData = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: fileURL)
            }.value
            guard !Task.isCancelled else { return }
        }
        guard let data = resolvedData else {
            image = nil
            thumbnail = nil
            isLoading = false
            return
        }

        if let cached = ImageCache.shared.cachedPreview(for: cacheKey, maxDimension: maxPixelSize) {
            image = cached
            thumbnail = nil
            isLoading = false
            return
        }

        image = nil
        isLoading = true

        if let cachedThumbnail = ImageCache.shared.cachedThumbnail(for: cacheKey, size: thumbnailSize) {
            thumbnail = cachedThumbnail
        } else {
            let thumbnailTask = ImageCache.shared.thumbnailTask(for: data, key: cacheKey, size: thumbnailSize)
            _ = await thumbnailTask.value
            guard !Task.isCancelled else { return }
            thumbnail = ImageCache.shared.cachedThumbnail(for: cacheKey, size: thumbnailSize)
        }

        let previewTask = ImageCache.shared.previewTask(for: data, key: cacheKey, maxDimension: maxPixelSize)
        _ = await previewTask.value

        guard !Task.isCancelled else { return }
        image = ImageCache.shared.cachedPreview(for: cacheKey, maxDimension: maxPixelSize)
        if image != nil { thumbnail = nil }
        isLoading = false
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.primary.opacity(0.05))

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var unavailableState: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .foregroundStyle(.tertiary)
            Text("[Image]")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 13))
    }
}
