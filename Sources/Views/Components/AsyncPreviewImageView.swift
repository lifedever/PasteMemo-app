import SwiftUI
import AppKit

struct AsyncPreviewImageView: View {
    let data: Data?
    let cacheKey: String
    var maxPixelSize: CGFloat = 1200
    var cornerRadius: CGFloat = 8
    var thumbnailSize: CGFloat = 240
    var onDoubleClick: (() -> Void)? = nil

    @State private var image: NSImage?
    @State private var thumbnail: NSImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else if data != nil {
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
        "\(cacheKey)_\(Int(maxPixelSize))_\(data?.count ?? 0)"
    }

    @MainActor
    private func loadImage() async {
        guard let data else {
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
