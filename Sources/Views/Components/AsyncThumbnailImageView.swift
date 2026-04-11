import SwiftUI
import AppKit

struct AsyncThumbnailImageView: View {
    let data: Data?
    let cacheKey: String
    var size: CGFloat = 36
    var cornerRadius: CGFloat = 6

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(0.05))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: taskID) {
            await loadThumbnail()
        }
    }

    private var taskID: String {
        "\(cacheKey)_\(Int(size))_\(data?.count ?? 0)"
    }

    @MainActor
    private func loadThumbnail() async {
        guard let data else {
            image = nil
            return
        }

        if let cached = ImageCache.shared.cachedThumbnail(for: cacheKey, size: size) {
            image = cached
            return
        }

        let task = ImageCache.shared.thumbnailTask(for: data, key: cacheKey, size: size)
        _ = await task.value
        guard !Task.isCancelled else { return }
        image = ImageCache.shared.cachedThumbnail(for: cacheKey, size: size)
    }
}
