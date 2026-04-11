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
    var sortMode: HistorySortMode = .lastUsed
    @AppStorage(OCRTaskCoordinator.enableOCRKey) private var ocrEnabled = true
    @AppStorage("imageLinkPreviewEnabled") private var imageLinkPreviewEnabled = true

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

                        fileCountBadge
                    }

                    HStack(spacing: 4) {
                        Text(formatTimeAgo(sortMode.date(for: item)))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        if let detail = secondaryDetailText {
                            Spacer().frame(width: 2)
                            Text(detail)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
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
        } else if item.contentType == .link, imageLinkPreviewEnabled,
                  LinkMetadataFetcher.isImageURL(item.content) {
            if let img = Self.decodeDataURIImage(item.content) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let url = URL(string: item.content) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
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
        } else if item.imageData != nil {
            AsyncThumbnailImageView(data: item.imageData, cacheKey: item.itemID)
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
            let icon = thumbnailIcon
            Image(systemName: icon.symbol)
                .font(.system(size: 14))
                .foregroundStyle(icon.color)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
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
                let icon = thumbnailIcon
                Image(systemName: icon.symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(icon.color)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
        .task(id: item.content) {
            let path = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Check cache first
            if let cached = ImageCache.shared.videoThumbnail(forPath: path) {
                videoThumb = cached
                return
            }
            let task = ImageCache.shared.videoThumbnailTask(forPath: path)
            _ = await task.value
            guard !Task.isCancelled else { return }
            videoThumb = ImageCache.shared.videoThumbnail(forPath: path)
        }
    }

    // MARK: - Helpers

    @AppStorage("showLinkURL") private var showLinkURL = false

    private var displayTitle: String {
        if item.isSensitive, !(isSelected && OptionKeyMonitor.shared.isOptionPressed) { return partialMask(item.content) }
        if item.contentType == .link, !showLinkURL, let linkTitle = item.linkTitle {
            return linkTitle
        }
        return item.displayTitle ?? item.content
    }

    private var secondaryDetailText: String? {
        switch item.contentType {
        case .code:
            let summary = QuickPreviewPane.buildCodeSummary(text: item.content, language: item.resolvedCodeLanguage)
            return "\(summary.language.displayName) · \(summary.lineCount)L"
        case .link:
            guard let url = URL(string: item.content.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return QuickPreviewPane.displayHost(for: url)
        default:
            return nil
        }
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
        return FileIconInfo(symbol: item.contentType.icon, color: .secondary)
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func decodeDataURIImage(_ content: String) -> NSImage? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:image/"),
              let commaIndex = trimmed.firstIndex(of: ",") else { return nil }
        let base64String = String(trimmed[trimmed.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }

    private var isMultiFile: Bool {
        item.contentType.isFileBased
            && item.content.contains("\n")
            && item.content != "[Image]"
    }

    @ViewBuilder
    private var fileCountBadge: some View {
        if isMultiFile {
            let count = item.content.components(separatedBy: "\n").count
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }
}
