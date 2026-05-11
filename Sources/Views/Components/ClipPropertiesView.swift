import SwiftUI
import AppKit

struct ClipPropertiesView: View {
    let item: ClipItem
    var fontSize: CGFloat = 12
    var onLocationTap: ((String) -> Void)?

    struct TextStats: Equatable, Sendable {
        let chars: Int
        let lines: Int
        let words: Int
    }

    @State private var textStats: TextStats?
    @State private var dataImageDimensions: CGSize?

    @ViewBuilder
    var body: some View {
        if item.isDeleted { EmptyView() } else {
        VStack(alignment: .leading, spacing: 0) {
            commonProperties
            typeSpecificProperties
            propDivider
            propRow(L10n.tr("detail.created"), formatDate(item.createdAt))
        }
        .task(id: "\(item.itemID):\(item.content.count)") {
            textStats = nil
            guard item.contentType == .text || item.contentType == .code else { return }
            let content = item.content
            let stats = await Task.detached(priority: .userInitiated) {
                let lines = content.components(separatedBy: .newlines)
                let words = content.components(separatedBy: .whitespacesAndNewlines)
                    .reduce(into: 0) { acc, s in if !s.isEmpty { acc += 1 } }
                return TextStats(chars: content.count, lines: lines.count, words: words)
            }.value
            if !Task.isCancelled {
                textStats = stats
            }
        }
        .task(id: "\(item.itemID):dataimg") {
            dataImageDimensions = nil
            guard item.contentType == .link,
                  DataImageURI.isBase64DataImageURI(item.content) else { return }
            let content = item.content
            let dims = await Task.detached(priority: .userInitiated) { () -> CGSize? in
                guard let data = DataImageURI.decodedImageData(from: content) else { return nil }
                return DataImageURI.dimensions(of: data)
            }.value
            if !Task.isCancelled {
                dataImageDimensions = dims
            }
        }
        }
    }

    // MARK: - Common

    private var isTextOrCode: Bool {
        item.contentType == .text || item.contentType == .code
    }

    private var commonProperties: some View {
        Group {
            if isTextOrCode {
                languageRow
            } else {
                propRow(L10n.tr("detail.type"), item.contentType.label)
            }
            propDivider
            if let app = item.sourceApp {
                appSourceRow(app)
            }
            if let agent = item.agentSource, !agent.isEmpty {
                propDivider
                aiAgentRow(agent)
            }
            if let groupName = item.groupName, !groupName.isEmpty {
                propDivider
                propRow(L10n.tr("detail.group"), groupName)
            }
        }
    }

    private var languageRow: some View {
        HStack {
            Text(L10n.tr("detail.language"))
                .font(.system(size: fontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Picker("", selection: languageSelection) {
                Text(L10n.tr("type.text")).tag("_text")
                Divider()
                Text("Auto").tag("_auto")
                Divider()
                ForEach(CodeLanguage.pickerChoices, id: \.self) { lang in
                    Text(lang.displayName).tag(lang.rawValue)
                }
            }
            .labelsHidden()
            .fixedSize()
            .font(.system(size: fontSize))
        }
        .padding(.vertical, fontSize <= 11 ? 3 : 4)
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: {
                guard !item.isDeleted else { return "_text" }
                if item.contentType == .text { return "_text" }
                if let raw = item.codeLanguage { return raw }
                return "_auto"
            },
            set: { newValue in
                if newValue == "_text" {
                    item.contentType = .text
                    item.codeLanguage = nil
                } else if newValue == "_auto" {
                    item.contentType = .code
                    item.codeLanguage = nil
                } else {
                    item.contentType = .code
                    item.codeLanguage = newValue
                }
            }
        )
    }

    private var currentDisplayLabel: String {
        if item.contentType == .text { return L10n.tr("type.text") }
        if let raw = item.codeLanguage, let lang = CodeLanguage(rawValue: raw) {
            return lang.displayName
        }
        // Auto-detected
        if let lang = CodeDetector.detectLanguage(item.content) {
            return "Auto (\(lang.displayName))"
        }
        return "Auto"
    }

    // MARK: - Type Specific

    @ViewBuilder
    private var typeSpecificProperties: some View {
        if item.contentType == .image, item.content != "[Image]", item.imageData == nil {
            fileProperties
        } else {
            specificProperties
        }
    }

    @ViewBuilder
    private var specificProperties: some View {
        switch item.contentType {
        case .image:
            imageProperties
        case .file, .video, .audio, .document, .archive, .application:
            fileProperties
        case .link:
            linkProperties
        default:
            textProperties
        }
    }

    // MARK: - Image

    @ViewBuilder
    private var imageProperties: some View {
        // For file-backed clips, read dimensions / size / format from the original
        // file on disk so the panel reports the real picture stats — not the small
        // thumbnail we keep in `imageData` for in-app preview.
        if let sourceURL = item.sourceImageFileURL {
            let dimensions = ImageCache.shared.imageDimensions(at: sourceURL)
            // Resolve symlinks before reading the file size — some sources
            // (Telegram's group container places the pasteboard image on a
            // *.jpg symlink to an extension-less real file) would otherwise
            // report the link node's size (~174 bytes, just the target path
            // string) instead of the actual image's size.
            let resolvedURL = sourceURL.resolvingSymlinksInPath()
            let fileSize = (try? resolvedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let dimensions {
                propDivider
                propRow(L10n.tr("detail.dimensions"), "\(Int(dimensions.width))×\(Int(dimensions.height))")
            }
            if fileSize > 0 {
                propDivider
                propRow(L10n.tr("detail.size"), formatFileSize(fileSize))
            }
            propDivider
            propRow(L10n.tr("detail.format"), formatFromExtension(sourceURL))
            let location = sourceURL.deletingLastPathComponent().path
            if !location.isEmpty {
                propDivider
                locationRow(location)
            }
        } else if let data = item.imageData, let dimensions = ImageCache.shared.imageDimensions(for: data) {
            // Raw pasteboard image (screenshot etc.) — `imageData` holds the originals.
            propDivider
            propRow(L10n.tr("detail.dimensions"), "\(Int(dimensions.width))×\(Int(dimensions.height))")
            propDivider
            propRow(L10n.tr("detail.size"), formatFileSize(data.count))
            propDivider
            propRow(L10n.tr("detail.format"), detectImageFormat(data))
        }
    }

    /// Best-effort image format label from a file extension. Used for file-backed
    /// clips where reading the magic bytes would require loading the original
    /// (potentially large) bytes; the extension is a reliable indicator for the
    /// formats Finder produces.
    private func formatFromExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "PNG"
        case "jpg", "jpeg": return "JPEG"
        case "gif": return "GIF"
        case "webp": return "WebP"
        case "heic", "heif": return "HEIC"
        case "tiff", "tif": return "TIFF"
        case "bmp": return "BMP"
        case "svg": return "SVG"
        default: return ext.isEmpty ? "—" : ext.uppercased()
        }
    }

    // MARK: - File

    private var fileProperties: some View {
        let paths = item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let itemCount = countItems(paths)
        let location = paths.count == 1
            ? URL(fileURLWithPath: paths[0]).deletingLastPathComponent().path
            : paths.compactMap { URL(fileURLWithPath: $0).deletingLastPathComponent().path }.first ?? ""
        let fileSize = calculatePlainFileSize(paths)
        return Group {
            propDivider
            propRow(L10n.tr("detail.fileCount"), "\(itemCount)")
            if fileSize > 0 {
                propDivider
                propRow(L10n.tr("detail.size"), formatFileSize(fileSize))
            }
            if !location.isEmpty {
                propDivider
                locationRow(location)
            }
        }
    }

    // MARK: - Link

    @ViewBuilder
    private var linkProperties: some View {
        if DataImageURI.isDataImageURI(item.content) {
            dataImageProperties
        } else {
            regularLinkProperties
        }
    }

    private var regularLinkProperties: some View {
        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if let title = item.linkTitle {
                propDivider
                propRow(L10n.tr("detail.linkTitle"), title)
            }
            propDivider
            propRow(L10n.tr("detail.url"), trimmed)
            if let url = URL(string: trimmed) {
                propDivider
                propRow(L10n.tr("detail.host"), url.host ?? "-")
            }
            propDivider
            propRow(L10n.tr("detail.chars"), "\(item.content.count)")
        }
    }

    /// Properties for inline `data:image/...` clipboard items — show the same
    /// dimensions/size/format trio as regular images so the panel doesn't fall
    /// silent for a clip type that's clearly a picture.
    @ViewBuilder
    private var dataImageProperties: some View {
        // Prefer the pre-decoded `imageData` populated at capture time: reading
        // dimensions / size / format from bytes is O(1) and skips re-decoding
        // the URI string. Falls back to the async-derived dimensions and the
        // URI header for legacy clips ingested before the pre-decode.
        if let data = item.imageData {
            if let dims = ImageCache.shared.imageDimensions(for: data) {
                propDivider
                propRow(L10n.tr("detail.dimensions"), "\(Int(dims.width))×\(Int(dims.height))")
            }
            propDivider
            propRow(L10n.tr("detail.size"), formatFileSize(data.count))
            if let format = imageFormatLabel(fromData: data) {
                propDivider
                propRow(L10n.tr("detail.format"), format)
            }
        } else {
            if let dims = dataImageDimensions {
                propDivider
                propRow(L10n.tr("detail.dimensions"), "\(Int(dims.width))×\(Int(dims.height))")
            }
            if DataImageURI.isBase64DataImageURI(item.content),
               let bytes = DataImageURI.estimatedDecodedSize(in: item.content) {
                propDivider
                propRow(L10n.tr("detail.size"), formatFileSize(bytes))
            }
            if let format = DataImageURI.formatLabel(in: item.content) {
                propDivider
                propRow(L10n.tr("detail.format"), format)
            }
        }
    }

    // MARK: - Text

    private var textProperties: some View {
        Group {
            propDivider
            propRow(L10n.tr("detail.chars"), textStats.map { "\($0.chars)" } ?? "…")
            propDivider
            propRow(L10n.tr("detail.lines"), textStats.map { "\($0.lines)" } ?? "…")
            propDivider
            propRow(L10n.tr("detail.words"), textStats.map { "\($0.words)" } ?? "…")
        }
    }

    // MARK: - Helpers

    private func appSourceRow(_ appName: String) -> some View {
        HStack {
            Text(L10n.tr("detail.source"))
                .font(.system(size: fontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 4) {
                if let icon = appIcon(forBundleID: item.sourceAppBundleID, name: appName) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: fontSize + 4, height: fontSize + 4)
                }
                Text(appName)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, fontSize <= 11 ? 3 : 4)
    }

    private func aiAgentRow(_ agentSource: String) -> some View {
        HStack {
            Text(L10n.tr("detail.aiAgent"))
                .font(.system(size: fontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 5) {
                Circle()
                    .fill(Self.agentColor(for: agentSource))
                    .frame(width: fontSize - 2, height: fontSize - 2)
                Text(Self.agentDisplayName(for: agentSource))
                    .font(.system(size: fontSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, fontSize <= 11 ? 3 : 4)
    }

    /// 已知 agent 的稳定颜色;未知 agent 用灰色兜底,文本就显示原始 clientName。
    static func agentColor(for source: String) -> Color {
        switch source.lowercased() {
        case "claude-code", "claude":           return .orange
        case "cursor", "cursor-vscode":         return .blue
        case "codex", "codex-cli":              return .green
        case "cline":                           return .purple
        default:                                return .gray
        }
    }

    static func agentDisplayName(for source: String) -> String {
        switch source.lowercased() {
        case "claude-code", "claude":           return "Claude Code"
        case "cursor", "cursor-vscode":         return "Cursor"
        case "codex", "codex-cli":              return "Codex"
        case "cline":                           return "Cline"
        default:                                return source
        }
    }

    private func locationRow(_ path: String) -> some View {
        Button {
            onLocationTap?(path)
        } label: {
            HStack {
                Text(L10n.tr("detail.location"))
                    .font(.system(size: fontSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 2) {
                    Text(path)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, fontSize <= 11 ? 3 : 4)
        }
        .buttonStyle(.plain)
    }

    private func propRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: fontSize))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Text(value)
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, fontSize <= 11 ? 3 : 4)
    }

    private var propDivider: some View {
        Divider().opacity(0.15)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Counts items: plain files count as 1, directories count their immediate children.
    private func countItems(_ paths: [String]) -> Int {
        let fm = FileManager.default
        var total = 0
        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let children = (try? fm.contentsOfDirectory(atPath: path))?.count ?? 0
                total += children
            } else {
                total += 1
            }
        }
        return total
    }

    /// Returns total size of plain files only. Directories return 0 (no recursive traversal).
    private func calculatePlainFileSize(_ paths: [String]) -> Int {
        let fm = FileManager.default
        var total = 0
        for path in paths {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let attrs = try? fm.attributesOfItem(atPath: path)
            total += (attrs?[.size] as? Int) ?? 0
        }
        return total
    }

    private func detectImageFormat(_ data: Data) -> String {
        guard data.count >= 4 else { return "Unknown" }
        let header = [UInt8](data.prefix(4))
        if header[0] == 0x89, header[1] == 0x50 { return "PNG" }
        if header[0] == 0xFF, header[1] == 0xD8 { return "JPEG" }
        if header[0] == 0x47, header[1] == 0x49 { return "GIF" }
        if header[0] == 0x49, header[1] == 0x49 { return "TIFF" }
        if header[0] == 0x4D, header[1] == 0x4D { return "TIFF" }
        if header[0] == 0x52, header[1] == 0x49 { return "WebP" }
        return "Image"
    }
}
