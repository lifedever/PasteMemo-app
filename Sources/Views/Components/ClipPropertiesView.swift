import SwiftUI
import AppKit

struct ClipPropertiesView: View {
    let item: ClipItem
    var fontSize: CGFloat = 12
    var onLocationTap: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            commonProperties
            typeSpecificProperties
            propDivider
            propRow(L10n.tr("detail.created"), formatDate(item.createdAt))
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
        if let data = item.imageData, let img = NSImage(data: data) {
            propDivider
            propRow(L10n.tr("detail.dimensions"), "\(Int(img.size.width))×\(Int(img.size.height))")
            propDivider
            propRow(L10n.tr("detail.size"), formatFileSize(data.count))
            propDivider
            propRow(L10n.tr("detail.format"), detectImageFormat(data))
            if item.content != "[Image]" {
                let location = URL(fileURLWithPath: item.content.components(separatedBy: "\n").first ?? "")
                    .deletingLastPathComponent().path
                if !location.isEmpty {
                    propDivider
                    locationRow(location)
                }
            }
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

    private var linkProperties: some View {
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

    // MARK: - Text

    private var textProperties: some View {
        let lines = item.content.components(separatedBy: .newlines)
        let words = item.content.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return Group {
            propDivider
            propRow(L10n.tr("detail.chars"), "\(item.content.count)")
            propDivider
            propRow(L10n.tr("detail.lines"), "\(lines.count)")
            propDivider
            propRow(L10n.tr("detail.words"), "\(words.count)")
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
