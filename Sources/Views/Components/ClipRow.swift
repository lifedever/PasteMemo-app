import SwiftUI
import AVFoundation

/// Shared clip row used by both QuickPanel and MainWindow
struct ClipRow: View {
    let item: ClipItem
    var isSelected: Bool = false
    var showThumbnail: Bool = true
    var groupIcon: String?
    var showGroupLabel: Bool = true
    var searchText: String = ""
    @AppStorage(OCRTaskCoordinator.enableOCRKey) private var ocrEnabled = true
    @AppStorage("imageLinkPreviewEnabled") private var imageLinkPreviewEnabled = true
    @State private var dataURIThumbnailImage: NSImage?

    var body: some View {
        if item.isDeleted {
            EmptyView()
        } else {
            HStack(spacing: 10) {
                if showThumbnail {
                    ZStack(alignment: .topLeading) {
                        thumbnail
                        if item.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .offset(x: -3, y: -3)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(displayTitle)
                            .font(.system(size: 13))
                            .lineLimit(1)

                        if ocrEnabled, item.matchesOCROnly(searchText: searchText) {
                            ocrBadge
                        }

                        Spacer()
                    }

                    HStack(spacing: 4) {
                        Text(formatTimeAgo(item.lastUsedAt))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        if showGroupLabel, let groupName = item.groupName, !groupName.isEmpty {
                            Spacer().frame(width: 2)
                            Image(systemName: groupIcon ?? "folder")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Text(groupName)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Thumbnail

    @State private var videoThumb: NSImage?

    @ViewBuilder
    private var thumbnail: some View {
        if item.isDeleted {
            EmptyView()
        } else if item.isSensitive {
            sensitiveThumbnail
        } else if item.contentType == .video, !item.content.contains("\n") {
            videoThumbnail
        } else if item.contentType == .image, let data = item.imageData,
           let img = ImageCache.shared.thumbnail(for: data, key: item.itemID) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) { imageFormatBadge }
        } else if item.contentType == .link, imageLinkPreviewEnabled,
                  DataImageURI.isBase64DataImageURI(item.content) {
            Group {
                if let img = dataURIThumbnailImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    linkFaviconThumbnail
                }
            }
            .task(id: item.itemID) {
                dataURIThumbnailImage = nil
                let content = item.content
                let data = await Task.detached(priority: .userInitiated) {
                    DataImageURI.decodedImageData(from: content)
                }.value
                guard !Task.isCancelled,
                      let data,
                      let image = NSImage(data: data) else { return }
                dataURIThumbnailImage = image
            }
        } else if item.contentType == .link, imageLinkPreviewEnabled,
                  LinkMetadataFetcher.isImageURL(item.content) {
            if let url = URL(string: item.content) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .bottomTrailing) { imageFormatBadge }
                    default:
                        linkFaviconThumbnail
                    }
                }
            } else {
                linkFaviconThumbnail
            }
        } else if item.contentType == .link {
            linkFaviconThumbnail
        } else if item.contentType == .color, let parsed = ColorConverter.parse(item.content) {
            Circle()
                .fill(Color(nsColor: parsed.nsColor))
                .frame(width: 28, height: 28)
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: Color(nsColor: parsed.nsColor).opacity(0.3), radius: 3, y: 1)
                .frame(width: 36, height: 36)
        } else if item.contentType.isFileBased, item.contentType != .image, !item.content.contains("\n") {
            let path = item.content.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isDirectory(path), !path.hasSuffix(".app") {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
            } else {
                Image(nsImage: ImageCache.shared.fileIcon(forPath: path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
            }
        } else if isMultiFile {
            let paths = item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
            let firstPath = paths.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: ImageCache.shared.fileIcon(forPath: firstPath))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                Text("\(paths.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
                    .offset(x: 2, y: 2)
            }
        } else if let data = item.imageData,
                  let img = ImageCache.shared.thumbnail(for: data, key: item.itemID) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) { imageFormatBadge }
        } else if item.contentType == .code {
            LanguageIcon(language: item.resolvedCodeLanguage ?? .unknown, size: 36)
        } else if item.contentType == .text || item.contentType == .email {
            Text(item.richTextData != nil ? "R" : "T")
                .font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.06))
                )
        } else {
            fileIconThumb(thumbnailIcon)
        }
    }

    @ViewBuilder
    private var imageFormatBadge: some View {
        if let label = resolvedImageFormatLabel {
            Text(label)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 0.5)
                .background(.black.opacity(0.55), in: Capsule())
        }
    }

    private var resolvedImageFormatLabel: String? {
        // File-backed image: derive from path extension (cheap, no data read).
        if item.content != "[Image]", !item.content.isEmpty {
            let firstPath = item.content.components(separatedBy: "\n").first ?? ""
            if let label = imageFormatLabel(forPath: firstPath) { return label }
        }
        // Raw pasteboard image: sniff magic bytes from stored thumbnail data.
        if let data = item.imageData {
            return imageFormatLabel(fromData: data)
        }
        return nil
    }

    @ViewBuilder
    private func fileIconThumb(_ icon: FileIconInfo) -> some View {
        ZStack(alignment: .bottom) {
            Image(systemName: icon.symbol)
                .font(.system(size: 14))
                .foregroundStyle(icon.color)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
            if let badge = icon.badge {
                Text(badge)
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.gray.opacity(0.85), in: Capsule())
                    .offset(y: -3)
            }
        }
    }

    @ViewBuilder
    private var linkFaviconThumbnail: some View {
        if let data = item.faviconData,
           let img = ImageCache.shared.favicon(for: data, key: item.content) {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05))
                    )
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(Color.blue, in: Circle())
                    .offset(x: 2, y: 2)
            }
        } else {
            Image(systemName: "link")
                .font(.system(size: 14))
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }

    private var videoThumbnail: some View {
        ZStack {
            if let thumb = videoThumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            } else {
                fileIconThumb(thumbnailIcon)
            }
        }
        .task(id: item.content) {
            let path = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Check cache first
            if let cached = ImageCache.shared.videoThumbnail(forPath: path) {
                videoThumb = cached
                return
            }
            let url = URL(fileURLWithPath: path)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 72, height: 72)
            if let cgImage = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image {
                let img = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                ImageCache.shared.setVideoThumbnail(img, forPath: path)
                videoThumb = img
            }
        }
    }

    // MARK: - Helpers

    @AppStorage("showLinkURL") private var showLinkURL = false

    private var displayTitle: String {
        if item.isSensitive, !(isSelected && OptionKeyMonitor.shared.isOptionPressed) { return partialMask(item.content) }
        if item.contentType == .link, !showLinkURL, let linkTitle = item.linkTitle {
            return linkTitle
        }
        if let title = item.displayTitle { return title }
        // Fallback for legacy items without a precomputed displayTitle — never
        // render megabytes of raw content: a truncated first-line preview is
        // enough for a list row and avoids freezing SwiftUI on huge pastes.
        let cap = 500
        let head = item.content.prefix(cap)
        let firstLine = head.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? String(head)
        return firstLine
    }

    private func partialMask(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let count = firstLine.count
        switch count {
        case 0...4:
            return String(repeating: "•", count: max(count, 1))
        case 5...6:
            return String(firstLine.prefix(1)) + String(repeating: "•", count: count - 2) + String(firstLine.suffix(1))
        default:
            return String(firstLine.prefix(2)) + "••••" + String(firstLine.suffix(2))
        }
    }

    private var sensitiveThumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.orange.opacity(0.1))
                )
            if let icon = appIcon(forBundleID: item.sourceAppBundleID, name: item.sourceApp) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var ocrBadge: some View {
        Text("OCR")
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.12), in: Capsule())
    }

    private var thumbnailIcon: FileIconInfo {
        if item.contentType.isFileBased, item.contentType != .image {
            let firstPath = item.content.components(separatedBy: "\n").first ?? ""
            return isMultiFile
                ? FileIconInfo(symbol: "square.stack.3d.up.fill", color: .cyan)
                : fileIconInfo(firstPath)
        }
        if item.contentType == .image, item.content != "[Image]" {
            let firstPath = item.content.components(separatedBy: "\n").first ?? ""
            return isMultiFile
                ? FileIconInfo(symbol: "square.stack.3d.up.fill", color: .cyan)
                : fileIconInfo(firstPath)
        }
        if item.contentType == .mixed {
            return FileIconInfo(symbol: "square.stack.3d.up.fill", color: .orange)
        }
        return FileIconInfo(symbol: item.contentType.icon, color: .secondary)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private var isMultiFile: Bool {
        item.contentType.isFileBased
            && item.content.contains("\n")
            && item.content != "[Image]"
    }

}
