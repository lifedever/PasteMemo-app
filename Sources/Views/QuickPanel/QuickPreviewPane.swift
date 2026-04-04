import SwiftUI
import AVFoundation
import AppKit

struct QuickPreviewPane: View {
    let item: ClipItem
    var searchText: String = ""
    @AppStorage(OCRTaskCoordinator.enableOCRKey) private var ocrEnabled = true

    private var isContentImage: Bool {
        item.contentType == .image && item.imageData != nil
    }

    private var isSingleFile: Bool {
        item.contentType.isFileBased && item.contentType != .image && !item.content.contains("\n")
    }

    private var isSingleVideo: Bool {
        item.contentType == .video && !item.content.contains("\n")
    }

    @ViewBuilder
    var body: some View {
        if item.isDeleted { EmptyView() } else {
        VStack(spacing: 0) {
            Group {
                if item.isSensitive {
                    SensitiveMask { quickContentArea }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    quickContentArea
                }
            }
            .background(Color.primary.opacity(0.04))

            Divider().opacity(0.3)

            propertiesSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        } // isDeleted guard
    }

    @ViewBuilder
    private var quickContentArea: some View {
        if isContentImage {
            imagePreviewWithOCR
        } else if isSingleVideo {
            videoPreview
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.contentType == .audio, !item.content.contains("\n") {
            AudioPlayerView(
                path: item.content.trimmingCharacters(in: .whitespacesAndNewlines),
                iconSize: 48,
                nameFont: .system(size: 13, weight: .medium),
                onOpenInFinder: { QuickPanelWindowController.shared.dismiss() }
            )
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.contentType == .code {
            CodePreviewView(code: item.content, language: item.resolvedCodeLanguage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.contentType == .text {
            previewContent
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.contentType == .color {
            colorPreview
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.contentType == .link {
            linkPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.contentType == .phone {
            phonePreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSingleFile {
            SingleFilePreview(
                path: item.content.trimmingCharacters(in: .whitespacesAndNewlines),
                iconSize: 48,
                nameFont: .system(size: 13, weight: .medium),
                onOpenInFinder: { QuickPanelWindowController.shared.dismiss() }
            )
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { previewContent }
                    .padding(.leading, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if item.contentType == .image, item.content != "[Image]", item.imageData == nil {
            // Multi image files from Finder (no imageData)
            filePreview
        } else {
            switch item.contentType {
            case .image:
                imagePreview
            case .video:
                if isSingleVideo { videoPreview } else { filePreview }
            case .audio:
                if isSingleFile { audioPreview } else { filePreview }
            case .file, .document, .archive, .application:
                filePreview
            case .color:
                colorPreview
            default:
                NativeTextView(text: item.content, richTextData: item.richTextData, richTextType: item.richTextType)
                    .id(item.persistentModelID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @State private var colorDisplayFormat: ColorFormat?

    @ViewBuilder
    private var colorPreview: some View {
        if let parsed = ColorConverter.parse(item.content) {
            let displayFmt = colorDisplayFormat ?? parsed.originalFormat
            VStack(spacing: 12) {
                Circle()
                    .fill(Color(nsColor: parsed.nsColor))
                    .frame(width: 64, height: 64)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    .shadow(color: Color(nsColor: parsed.nsColor).opacity(0.4), radius: 8, y: 3)

                Text(parsed.formatted(displayFmt))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    ForEach(ColorFormat.allCases, id: \.self) { fmt in
                        Button {
                            colorDisplayFormat = fmt
                            item.content = parsed.formatted(fmt)
                            item.displayTitle = item.content
                        } label: {
                            Text(fmt.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    displayFmt == fmt
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.primary.opacity(0.05),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .onChange(of: item.id) { colorDisplayFormat = nil }
        } else {
            // Fallback: show raw color text if parsing fails
            Text(item.content)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        AsyncPreviewImageView(
            data: item.imageData,
            cacheKey: item.itemID,
            maxPixelSize: 1100,
            cornerRadius: 6,
            onDoubleClick: {
                QuickLookHelper.shared.openInPreviewApp(item: item)
            }
        )
        .pointerCursor()
    }

    private var imagePreviewWithOCR: some View {
        return VStack(spacing: 10) {
            imagePreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if ocrEnabled, let ocrText = item.ocrText, !ocrText.isEmpty {
                ocrSnippetCard(text: ocrText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ocrSnippetCard(text: String) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("OCR")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                Text(L10n.tr("quick.ocrMatch"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("detail.ocr.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            ScrollView {
                Text(ocrSnippetText(from: text))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .frame(minHeight: 56, maxHeight: 120)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func buildOCRSnippet(text: String, query: String) -> AttributedString {
        let compact = text.replacingOccurrences(of: #"[^\S\n]+"#, with: " ", options: .regularExpression)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let snippet: String = {
            guard !compact.isEmpty else { return compact }
            guard !trimmedQuery.isEmpty,
                  let range = compact.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive])
            else {
                let prefix = compact.prefix(220)
                return compact.count > 220 ? String(prefix) + "…" : String(prefix)
            }

            let contextRadius = 72
            let lowerDistance = compact.distance(from: compact.startIndex, to: range.lowerBound)
            let upperDistance = compact.distance(from: compact.startIndex, to: range.upperBound)
            let start = compact.index(range.lowerBound, offsetBy: -min(contextRadius, lowerDistance))
            let end = compact.index(range.upperBound, offsetBy: min(contextRadius, compact.count - upperDistance))
            var snippet = String(compact[start..<end])
            if start > compact.startIndex { snippet = "…" + snippet }
            if end < compact.endIndex { snippet += "…" }
            return snippet
        }()

        var attributed = AttributedString(snippet)

        if !trimmedQuery.isEmpty,
           let highlightRange = attributed.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[highlightRange].backgroundColor = .yellow.opacity(0.35)
            attributed[highlightRange].foregroundColor = .primary
        }
        return attributed
    }

    private func ocrSnippetText(from text: String) -> AttributedString {
        Self.buildOCRSnippet(text: text, query: searchText)
    }

    private var videoPreview: some View {
        VideoThumbnailView(path: item.content.trimmingCharacters(in: .whitespacesAndNewlines))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var audioPreview: some View {
        AudioPlayerView(
            path: item.content.trimmingCharacters(in: .whitespacesAndNewlines),
            iconSize: 48,
            nameFont: .system(size: 13, weight: .medium),
            onOpenInFinder: { QuickPanelWindowController.shared.dismiss() }
        )
    }

    @ViewBuilder
    private var filePreview: some View {
        let paths = item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
        if paths.count == 1, let path = paths.first {
            SingleFilePreview(
                path: path,
                iconSize: 48,
                nameFont: .system(size: 13, weight: .medium),
                onOpenInFinder: { QuickPanelWindowController.shared.dismiss() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                    FileRow(path: path, onOpenInFinder: { QuickPanelWindowController.shared.dismiss() })
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @AppStorage("webPreviewEnabled") private var webPreviewEnabled = true

    @ViewBuilder
    private var linkPreview: some View {
        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            if webPreviewEnabled {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        if let data = item.faviconData, let img = NSImage(data: data) {
                            Image(nsImage: img)
                                .resizable()
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "link")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Text(trimmed)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("detail.openInBrowser"))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                    WebPreviewView(url: url)
                        .id(url)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            } else {
                linkStaticPreview(url: url)
            }
        } else {
            NativeTextView(text: item.content, richTextData: item.richTextData, richTextType: item.richTextType)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
        }
    }

    // MARK: - Link Static Preview

    @State private var isLinkButtonHovered = false

    @ViewBuilder
    private func linkStaticPreview(url: URL) -> some View {
        VStack(spacing: 12) {
            if let img = validFavicon(minSize: 32) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
            }

            Text(url.absoluteString)
                .font(.system(size: 13))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            if let title = item.linkTitle {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 4) {
                    Image(nsImage: defaultBrowserIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                    Text(L10n.tr("detail.openInBrowser"))
                        .font(.system(size: 12))
                }
                .foregroundStyle(isLinkButtonHovered ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .onHover { isLinkButtonHovered = $0 }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func validFavicon(minSize: CGFloat) -> NSImage? {
        guard let data = item.faviconData, let img = NSImage(data: data) else { return nil }
        let size = img.representations.first.map { CGFloat(max($0.pixelsWide, $0.pixelsHigh)) } ?? max(img.size.width, img.size.height)
        return size >= minSize ? img : nil
    }

    private var defaultBrowserIcon: NSImage {
        guard let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://")!) else {
            return NSWorkspace.shared.icon(for: .html)
        }
        return NSWorkspace.shared.icon(forFile: browserURL.path)
    }

    // MARK: - Phone Preview

    private var phonePreview: some View {
        let number = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 20) {
            Image(systemName: "phone.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.mint)

            Text(number)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .textSelection(.enabled)

            HStack(spacing: 16) {
                phoneActionButton(
                    icon: "phone.fill",
                    label: L10n.tr("phone.call"),
                    color: .green
                ) {
                    if let url = URL(string: "tel:\(number)") {
                        NSWorkspace.shared.open(url)
                    }
                }

                phoneActionButton(
                    icon: "message.fill",
                    label: L10n.tr("phone.message"),
                    color: .blue
                ) {
                    if let url = URL(string: "sms:\(number)") {
                        NSWorkspace.shared.open(url)
                    }
                }

                phoneActionButton(
                    icon: "doc.on.doc.fill",
                    label: L10n.tr("phone.copy"),
                    color: .orange
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(number, forType: .string)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func phoneActionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(color)
                    .frame(width: 40, height: 40)
                    .background(color.opacity(0.1), in: Circle())
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Properties

    private var propertiesSection: some View {
        ClipPropertiesView(item: item, fontSize: 11) { path in
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            QuickPanelWindowController.shared.dismiss()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
