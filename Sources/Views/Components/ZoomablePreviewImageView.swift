import SwiftUI
import AppKit

enum ZoomLayoutMode: Equatable {
    case fitWidth
    case actualSize
}

// MARK: - Zoomable scroll view (AppKit)

/// Container documentView that holds the image view centered inside itself.
/// Flipped so top-left is (0, 0), which makes scroll-to-top math obvious.
final class CenteredImageDocumentView: NSView {
    let imageView = NSImageView()

    init() {
        super.init(frame: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
}

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
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 8.0

        let documentView = CenteredImageDocumentView()
        scrollView.documentView = documentView

        context.coordinator.scrollView = scrollView
        context.coordinator.documentView = documentView
        context.coordinator.onMagnificationChanged = onMagnificationChanged

        // updateNSView often fires before the scroll view is attached to a
        // window — clip bounds are still 0. Listen for frame changes so we
        // can re-run layout once the view actually has a size.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipFrameChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )
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

    // NSScrollView has no intrinsicContentSize; without sizeThatFits SwiftUI
    // hands it unbounded space and it overflows the panel.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? image.size.width,
            height: proposal.height ?? image.size.height
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPending()
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var documentView: CenteredImageDocumentView?
        var onMagnificationChanged: ((CGFloat) -> Void)?
        private var lastResetToken: UUID?
        private var lastImageRef: NSImage?
        private var lastLayoutMode: ZoomLayoutMode?
        private var pendingLayoutMode: ZoomLayoutMode?
        private var pendingImage: NSImage?

        func cancelPending() {
            pendingLayoutMode = nil
            pendingImage = nil
        }

        func apply(image: NSImage, cornerRadius: CGFloat, layoutMode: ZoomLayoutMode, resetToken: UUID) {
            guard let documentView else { return }

            let imageChanged = lastImageRef !== image
            let shouldResetLayout = lastResetToken != resetToken || imageChanged || lastLayoutMode != layoutMode

            if imageChanged {
                documentView.imageView.image = image
                lastImageRef = image
            }

            // Intentionally no cornerRadius on the image itself — clipping
            // the original bitmap is misleading for screenshots and copied
            // images. The cornerRadius parameter still styles placeholders.

            if shouldResetLayout {
                lastResetToken = resetToken
                lastLayoutMode = layoutMode
                scheduleLayout(mode: layoutMode, image: image)
            }
        }

        // Try layout synchronously. If the scroll view isn't laid out yet
        // (clipSize == 0 — common right after makeNSView before the view is
        // attached to a window), keep pending state and wait for the clip
        // view's frameDidChange notification to retry. This is more reliable
        // than polling on dispatch_async, which can drop the retry budget
        // before SwiftUI attaches the view.
        private func scheduleLayout(mode: ZoomLayoutMode, image: NSImage) {
            pendingLayoutMode = mode
            pendingImage = image
            tryApplyLayout()
        }

        private func tryApplyLayout() {
            guard let mode = pendingLayoutMode,
                  let image = pendingImage,
                  let scrollView,
                  let documentView else { return }

            scrollView.layoutSubtreeIfNeeded()
            let clipSize = scrollView.contentView.bounds.size
            let imageSize = image.size

            guard clipSize.width > 0, clipSize.height > 0,
                  imageSize.width > 0, imageSize.height > 0 else {
                // Keep pending; clipFrameChanged will call us again once the
                // scroll view gets a non-zero size.
                return
            }

            pendingLayoutMode = nil
            pendingImage = nil

            applyLayout(mode: mode, clipSize: clipSize, imageSize: imageSize,
                        scrollView: scrollView, documentView: documentView)
        }

        @objc func clipFrameChanged(_ notification: Notification) {
            tryApplyLayout()
        }

        // Strategy: control display size via frame, not magnification.
        // - .fitWidth (semantically aspect-fit): image scaled to fit entirely
        //   within the clip view; small images stay at 1×.
        // - .actualSize: image at its real pixel size; scrolls if larger than clip.
        // documentView is sized to max(clipSize, imageSize) so small images get
        // centered inside the clip view (no built-in NSClipView centering).
        private func applyLayout(mode: ZoomLayoutMode, clipSize: NSSize, imageSize: NSSize,
                                 scrollView: NSScrollView, documentView: CenteredImageDocumentView) {
            let scaledSize: NSSize
            switch mode {
            case .fitWidth:
                let scale = min(1.0,
                                min(clipSize.width / imageSize.width,
                                    clipSize.height / imageSize.height))
                scaledSize = NSSize(width: imageSize.width * scale,
                                    height: imageSize.height * scale)
            case .actualSize:
                scaledSize = imageSize
            }

            let docSize = NSSize(
                width: max(clipSize.width, scaledSize.width),
                height: max(clipSize.height, scaledSize.height)
            )

            documentView.frame = NSRect(origin: .zero, size: docSize)
            documentView.imageView.frame = NSRect(
                x: (docSize.width - scaledSize.width) / 2,
                y: (docSize.height - scaledSize.height) / 2,
                width: scaledSize.width,
                height: scaledSize.height
            )

            // Reset zoom; frame controls display size.
            scrollView.magnification = 1.0

            let scrollOrigin: NSPoint
            switch mode {
            case .fitWidth:
                // Center horizontally if doc is wider than image; top-aligned
                // since long content reads top-to-bottom. (Flipped: y=0 is top.)
                scrollOrigin = NSPoint(
                    x: max(0, (docSize.width - clipSize.width) / 2),
                    y: 0
                )
            case .actualSize:
                scrollOrigin = NSPoint(
                    x: max(0, (docSize.width - clipSize.width) / 2),
                    y: max(0, (docSize.height - clipSize.height) / 2)
                )
            }
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
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
    @State private var isHovered = false

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
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                    .animation(.easeInOut(duration: 0.18), value: isHovered)
                    .zIndex(1)
            }
        }
        .onHover { isHovered = $0 }
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
            zoomButton(title: toggleTitle, systemImage: toggleIcon) {
                toggleFitOrActual()
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

    // Icon shows the *target* mode the click will switch to, matching the
    // common toggle-button idiom.
    private var toggleIcon: String {
        layoutMode == .fitWidth ? "1.magnifyingglass" : "arrow.up.left.and.arrow.down.right"
    }

    private var toggleTitle: String {
        L10n.tr(layoutMode == .fitWidth ? "preview.image.zoomActual" : "preview.image.zoomFit")
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
