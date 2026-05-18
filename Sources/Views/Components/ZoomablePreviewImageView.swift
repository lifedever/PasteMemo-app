import SwiftUI
import AppKit

enum ZoomLayoutMode: Equatable {
    case fitWidth
    case actualSize
}

// MARK: - Zoomable scroll view (AppKit)

struct ZoomableImageScrollView: NSViewRepresentable {
    let image: NSImage
    var cornerRadius: CGFloat = 8
    var layoutMode: ZoomLayoutMode = .fitWidth
    var resetToken: UUID = UUID()
    var onMagnificationChanged: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8.0

        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        scrollView.documentView = imageView

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.onMagnificationChanged = onMagnificationChanged

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationDidChange(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationDidChange(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onMagnificationChanged = onMagnificationChanged
        context.coordinator.apply(
            image: image,
            cornerRadius: cornerRadius,
            layoutMode: layoutMode,
            resetToken: resetToken
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var imageView: NSImageView?
        var onMagnificationChanged: ((CGFloat) -> Void)?
        private var lastResetToken: UUID?
        private var lastImageRef: NSImage?

        private var lastLayoutMode: ZoomLayoutMode?

        func apply(image: NSImage, cornerRadius: CGFloat, layoutMode: ZoomLayoutMode, resetToken: UUID) {
            guard let scrollView, let imageView else { return }

            let imageChanged = lastImageRef !== image
            let shouldResetLayout = lastResetToken != resetToken || imageChanged || lastLayoutMode != layoutMode

            if imageChanged {
                imageView.image = image
                let size = image.size
                imageView.frame = NSRect(origin: .zero, size: size)
                scrollView.documentView = imageView
                lastImageRef = image
            }

            imageView.wantsLayer = cornerRadius > 0
            imageView.layer?.cornerRadius = cornerRadius
            imageView.layer?.masksToBounds = cornerRadius > 0

            if shouldResetLayout {
                lastResetToken = resetToken
                lastLayoutMode = layoutMode
                Task { @MainActor [weak self] in
                    switch layoutMode {
                    case .fitWidth:
                        self?.applyFitWidth()
                    case .actualSize:
                        self?.applyActualSize()
                    }
                }
            }
        }

        func applyFitWidth() {
            guard let scrollView, let imageView, imageView.bounds.width > 0 else { return }
            scrollView.layoutSubtreeIfNeeded()
            let clipWidth = scrollView.contentView.bounds.width
            guard clipWidth > 0 else { return }
            let scale = clipWidth / imageView.bounds.width
            scrollView.magnification = max(scale, scrollView.minMagnification)
            scrollView.scrollToVisible(NSRect(x: 0, y: imageView.bounds.height - 1, width: 1, height: 1))
        }

        func applyActualSize() {
            guard let scrollView else { return }
            scrollView.magnification = 1.0
        }

        @objc func magnificationDidChange(_ notification: Notification) {
            guard let scrollView = notification.object as? NSScrollView else { return }
            onMagnificationChanged?(scrollView.magnification)
        }
    }
}

// MARK: - SwiftUI wrapper

struct ZoomablePreviewImageView: View {
    let source: ClipImagePreviewSource?
    var maxPixelSize: CGFloat = 1200
    var thumbnailSize: CGFloat = 240
    var cornerRadius: CGFloat = 8
    var onDoubleClick: (() -> Void)?
    var onOpenInPreview: (() -> Void)?

    @State private var image: NSImage?
    @State private var thumbnail: NSImage?
    @State private var isLoading = false
    @State private var layoutResetToken = UUID()
    @State private var layoutMode: ZoomLayoutMode = .fitWidth

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    ZoomableImageScrollView(
                        image: image,
                        cornerRadius: cornerRadius,
                        layoutMode: layoutMode,
                        resetToken: layoutResetToken
                    )
                    .id("\(source?.cacheKey ?? "")-\(layoutResetToken)-\(layoutMode)")
                } else if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if source != nil {
                    placeholder
                } else {
                    unavailableState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if let onDoubleClick {
                    onDoubleClick()
                } else {
                    toggleFitOrActual()
                }
            }

            if image != nil {
                zoomToolbar
                    .padding(8)
                    .zIndex(1)
            }
        }
        .task(id: taskID) {
            await loadImage()
        }
    }

    private var taskID: String {
        guard let source else { return "empty" }
        switch source {
        case .inMemory(let data, let key):
            return "mem_\(key)_\(Int(maxPixelSize))_\(data.count)"
        case .file(let url, let key):
            return "file_\(key)_\(Int(maxPixelSize))_\(url.path)"
        }
    }

    private var zoomToolbar: some View {
        HStack(spacing: 4) {
            zoomButton(title: L10n.tr("preview.image.zoomFit"), systemImage: "arrow.up.left.and.arrow.down.right") {
                layoutMode = .fitWidth
                layoutResetToken = UUID()
            }
            zoomButton(title: L10n.tr("preview.image.zoomActual"), systemImage: "1.magnifyingglass") {
                layoutMode = .actualSize
                layoutResetToken = UUID()
            }
            if let onOpenInPreview {
                zoomButton(title: L10n.tr("preview.image.openInPreview"), systemImage: "eye") {
                    onOpenInPreview()
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .help(L10n.tr("preview.image.zoomHint"))
    }

    private func zoomButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func toggleFitOrActual() {
        layoutMode = layoutMode == .fitWidth ? .actualSize : .fitWidth
        layoutResetToken = UUID()
    }

    @MainActor
    private func loadImage() async {
        guard let source else {
            image = nil
            thumbnail = nil
            isLoading = false
            return
        }

        let cacheKey = source.cacheKey

        if let cached = ImageCache.shared.cachedPreview(for: cacheKey, maxDimension: maxPixelSize) {
            image = cached
            thumbnail = nil
            isLoading = false
            layoutMode = .fitWidth
            layoutResetToken = UUID()
            return
        }

        image = nil
        isLoading = true
        layoutMode = .fitWidth

        switch source {
        case .inMemory(let data, _):
            await loadInMemoryPreview(data: data, cacheKey: cacheKey)
        case .file(let url, _):
            await loadFilePreview(url: url, cacheKey: cacheKey)
        }

        guard !Task.isCancelled else { return }
        image = ImageCache.shared.cachedPreview(for: cacheKey, maxDimension: maxPixelSize)
        if image != nil { thumbnail = nil }
        isLoading = false
        layoutMode = .fitWidth
        layoutResetToken = UUID()
    }

    @MainActor
    private func loadInMemoryPreview(data: Data, cacheKey: String) async {
        if thumbnail == nil {
            if let cachedThumb = ImageCache.shared.cachedThumbnail(for: cacheKey, size: thumbnailSize) {
                thumbnail = cachedThumb
            } else {
                let thumbTask = ImageCache.shared.thumbnailTask(for: data, key: cacheKey, size: thumbnailSize)
                _ = await thumbTask.value
                guard !Task.isCancelled else { return }
                thumbnail = ImageCache.shared.cachedThumbnail(for: cacheKey, size: thumbnailSize)
            }
        }

        let previewTask = ImageCache.shared.previewTask(for: data, key: cacheKey, maxDimension: maxPixelSize)
        _ = await previewTask.value
    }

    @MainActor
    private func loadFilePreview(url: URL, cacheKey: String) async {
        let previewTask = ImageCache.shared.previewTask(forFileAt: url, key: cacheKey, maxDimension: maxPixelSize)
        _ = await previewTask.value

        if thumbnail == nil, let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
           data.count <= 512 * 1024 {
            let thumbTask = ImageCache.shared.thumbnailTask(for: data, key: cacheKey, size: thumbnailSize)
            _ = await thumbTask.value
            guard !Task.isCancelled else { return }
            thumbnail = ImageCache.shared.cachedThumbnail(for: cacheKey, size: thumbnailSize)
        }
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

// MARK: - Clip item convenience

struct ZoomableClipImagePreview: View {
    let item: ClipItem
    var supplementalData: Data? = nil
    var maxPixelSize: CGFloat = 1200
    var thumbnailSize: CGFloat = 240
    var cornerRadius: CGFloat = 8
    var onDoubleClick: (() -> Void)? = nil

    var body: some View {
        ZoomablePreviewImageView(
            source: ClipImagePreviewSource.resolve(from: item, supplementalData: supplementalData),
            maxPixelSize: maxPixelSize,
            thumbnailSize: thumbnailSize,
            cornerRadius: cornerRadius,
            onDoubleClick: onDoubleClick,
            onOpenInPreview: { QuickLookHelper.shared.openInPreviewApp(item: item) }
        )
    }
}
