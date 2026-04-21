import SwiftUI
import AVFoundation
import AppKit
import SwiftData

struct QuickPreviewPane: View {
    let item: ClipItem
    var searchText: String = ""
    @AppStorage(OCRTaskCoordinator.enableOCRKey) private var ocrEnabled = true
    @State private var allowHeavyPreview = false
    @State private var webPreviewReady = false
    @State private var cachedCodeSummary: CodePreviewSummary?
    @State private var reviewDraft = ""
    @State private var reviewBoundItemID = ""
    @State private var reviewAutosaveTask: Task<Void, Never>?

    struct CodePreviewSummary: Equatable {
        let language: CodeLanguage
        let lineCount: Int
        let characterCount: Int
        let snippet: String
        let isTruncated: Bool
        let supportsExpandedPreview: Bool
    }

    private var isContentImage: Bool {
        item.contentType == .image && item.imageData != nil
    }

    private var isSingleFile: Bool {
        item.contentType.isFileBased && item.contentType != .image && !item.content.contains("\n")
    }

    private var isSingleVideo: Bool {
        item.contentType == .video && !item.content.contains("\n")
    }

    private var heavyPreviewDelay: Duration {
        switch item.contentType {
        case .code, .link:
            return .milliseconds(260)
        default:
            return .milliseconds(120)
        }
    }

    private var codeSummary: CodePreviewSummary {
        // For huge payloads, buildCodeSummary splits the whole string by
        // newlines — a 10 MB paste can block the main thread for hundreds
        // of ms per render. We lazily cache the result and compute it off
        // the main actor in `.task(id:)`; a lightweight fallback is used
        // only on the very first render.
        if let cached = cachedCodeSummary {
            return cached
        }
        return Self.cheapCodeSummary(text: item.content, language: item.resolvedCodeLanguage)
    }

    /// O(preview limit) summary used as an instant placeholder while the
    /// detached task computes the real summary. It never scans the full
    /// content, so even multi-megabyte items stay responsive.
    static func cheapCodeSummary(
        text: String,
        language: CodeLanguage?,
        previewLineLimit: Int = 8,
        previewCharacterLimit: Int = 420
    ) -> CodePreviewSummary {
        let resolvedLanguage = language ?? .unknown
        let head = String(text.prefix(previewCharacterLimit * 2))
        let lines = head.components(separatedBy: .newlines)
        let previewLines = Array(lines.prefix(previewLineLimit)).joined(separator: "\n")
        var snippet = String(previewLines.prefix(previewCharacterLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let textCount = text.count
        let approxTruncated = text.count > head.count || lines.count > previewLineLimit
        if approxTruncated, !snippet.isEmpty, !snippet.hasSuffix("…") {
            snippet += "…"
        }
        return CodePreviewSummary(
            language: resolvedLanguage,
            lineCount: max(lines.count, 1),
            characterCount: textCount,
            snippet: snippet,
            isTruncated: approxTruncated,
            supportsExpandedPreview: false
        )
    }

    @ViewBuilder
    var body: some View {
        if item.isDeleted || item.modelContext == nil { EmptyView() } else {
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
        .onAppear { loadReviewFromCurrentItem() }
        .onDisappear {
            flushReviewDraft(notify: true)
            reviewAutosaveTask?.cancel()
            reviewAutosaveTask = nil
        }
        .onChange(of: item.persistentModelID) {
            flushReviewDraft(notify: true)
            loadReviewFromCurrentItem()
        }
        .task(id: item.persistentModelID) {
            allowHeavyPreview = false
            webPreviewReady = false
            cachedCodeSummary = nil
            retryLinkMetadataIfNeeded()

            if item.contentType == .code {
                let content = item.content
                let lang = item.resolvedCodeLanguage
                let summary = await Task.detached(priority: .userInitiated) {
                    QuickPreviewPane.buildCodeSummary(text: content, language: lang)
                }.value
                if !Task.isCancelled {
                    cachedCodeSummary = summary
                }
            }

            try? await Task.sleep(for: heavyPreviewDelay)
            guard !Task.isCancelled else { return }
            allowHeavyPreview = true
        }
        } // zombie-object guard: isDeleted alone is unsafe after deleteAndNotify — see QuickPanelView.swift
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
            codePreview
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
                    .padding(.horizontal, 14)
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
                NativeTextView(
                    text: item.content,
                    richTextData: item.richTextData,
                    richTextType: item.richTextType,
                    allowRichRender: allowHeavyPreview,
                    itemID: item.itemID
                )
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
            thumbnailSize: 180,
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
    @AppStorage("imageLinkPreviewEnabled") private var imageLinkPreviewEnabled = true

    @ViewBuilder
    private var linkPreview: some View {
        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            let webviewActive = ((imageLinkPreviewEnabled && LinkMetadataFetcher.isImageURL(trimmed)) || webPreviewEnabled) && allowHeavyPreview
            if webviewActive {
                ZStack {
                    // WebView 始终驻留，加载完成前透明
                    VStack(alignment: .leading, spacing: 0) {
                        linkSummaryHeader(url: url)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 10)

                        Divider().opacity(0.25)

                        WebPreviewView(url: url) { ready in
                            webPreviewReady = ready
                        }
                        .id(url)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    }
                    .opacity(webPreviewReady ? 1 : 0)

                    // 加载态只显示居中大卡，不显示上方 header/按钮
                    if !webPreviewReady {
                        linkStaticPreview(url: url)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                    }
                }
            } else {
                linkStaticPreview(url: url)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            }
        } else {
            NativeTextView(
                text: item.content,
                richTextData: item.richTextData,
                richTextType: item.richTextType,
                allowRichRender: allowHeavyPreview,
                itemID: item.itemID
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
        }
    }

    // MARK: - Link Static Preview

    @State private var isLinkButtonHovered = false
    @State private var isCopyButtonHovered = false

    @ViewBuilder
    private var codePreview: some View {
        let summary = codeSummary

        if allowHeavyPreview, summary.supportsExpandedPreview {
            CodePreviewView(
                code: item.content,
                language: item.resolvedCodeLanguage,
                deferredHighlightDelayMs: 120,
                maximumHighlightedCharacters: 12_000
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(summary.snippet)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func linkSummaryHeader(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if let img = validFavicon(minSize: 24) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        quickMetadataBadge(Self.displayHost(for: url))
                        if let scheme = url.scheme?.uppercased(), !scheme.isEmpty {
                            quickMetadataBadge(scheme)
                        }

                        Spacer(minLength: 8)

                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 4) {
                                Image(nsImage: defaultBrowserIcon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 14, height: 14)
                                Text(L10n.tr("detail.openInBrowser"))
                                    .font(.system(size: 12))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        } label: {
                            Label(L10n.tr("action.copy"), systemImage: "doc.on.doc")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if let title = item.linkTitle, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Text(url.absoluteString)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func quickMetadataBadge(_ text: String) -> some View {
        // Bump lowercase text slightly so its x-height roughly matches
        // cap-height of uppercase siblings (e.g. "HTTPS" badge).
        let hasLowercase = text.contains(where: { $0.isLowercase })
        return Text(text)
            .font(.system(size: hasLowercase ? 12 : 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    @ViewBuilder
    private func linkStaticPreview(url: URL) -> some View {
        VStack(spacing: 10) {
            if let img = validFavicon(minSize: 32) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }

            if let title = item.linkTitle, !title.isEmpty {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                quickMetadataBadge(Self.displayHost(for: url))
                if let scheme = url.scheme?.uppercased(), !scheme.isEmpty {
                    quickMetadataBadge(scheme)
                }
            }

            Text(url.absoluteString)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            let path = Self.displayPath(for: url)
            if !path.isEmpty {
                Text(path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 12) {
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

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13))
                        Text(L10n.tr("action.copy"))
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(isCopyButtonHovered ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .onHover { isCopyButtonHovered = $0 }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func retryLinkMetadataIfNeeded() {
        guard item.contentType == .link,
              item.linkTitle == nil,
              let context = item.modelContext,
              let _ = URL(string: item.content.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        let targetItem = item
        Task {
            let metadata = await LinkMetadataFetcher.shared.fetchMetadata(urlString: targetItem.content)
            await MainActor.run {
                guard !targetItem.isDeleted else { return }
                if let title = metadata.title, !title.isEmpty { targetItem.linkTitle = title }
                if let favicon = metadata.faviconData, targetItem.faviconData == nil { targetItem.faviconData = favicon }
                ClipItemStore.saveAndNotifyContent(context)
            }
        }
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

    nonisolated static func buildCodeSummary(
        text: String,
        language: CodeLanguage?,
        previewLineLimit: Int = 8,
        previewCharacterLimit: Int = 420,
        expandedPreviewCharacterLimit: Int = 20_000
    ) -> CodePreviewSummary {
        let resolvedLanguage = language ?? .unknown
        let lines = text.components(separatedBy: .newlines)
        let lineCount = max(lines.count, 1)
        let previewLines = Array(lines.prefix(previewLineLimit)).joined(separator: "\n")
        var snippet = String(previewLines.prefix(previewCharacterLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        let isTruncated = lineCount > previewLineLimit || previewLines.count > previewCharacterLimit

        if snippet.isEmpty {
            snippet = String(text.prefix(min(previewCharacterLimit, text.count))).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if isTruncated, !snippet.isEmpty, !snippet.hasSuffix("…") {
            snippet += "…"
        }

        return CodePreviewSummary(
            language: resolvedLanguage,
            lineCount: lineCount,
            characterCount: text.count,
            snippet: snippet,
            isTruncated: isTruncated,
            supportsExpandedPreview: text.count <= expandedPreviewCharacterLimit
        )
    }

    static func displayHost(for url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? url.host ?? url.absoluteString
        return host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    static func displayPath(for url: URL) -> String {
        var parts: [String] = []
        let path = url.path
        if !path.isEmpty, path != "/" {
            parts.append(path)
        }
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query, !query.isEmpty {
            parts.append("?\(query)")
        }
        return parts.joined()
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
        VStack(spacing: 6) {
            ClipPropertiesView(item: item, fontSize: 11) { path in
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                QuickPanelWindowController.shared.dismiss()
            }
            reviewSection
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.tr("detail.review"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(L10n.tr("detail.review.autosave"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            NativeTextView(
                text: reviewDraft,
                isEditable: true,
                onTextChange: { newText in
                    reviewDraft = newText
                    scheduleReviewAutosave()
                }
            )
            .frame(minHeight: 64, maxHeight: 104)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    private func loadReviewFromCurrentItem() {
        reviewAutosaveTask?.cancel()
        reviewAutosaveTask = nil
        reviewBoundItemID = item.itemID
        reviewDraft = item.review ?? ""
    }

    private func scheduleReviewAutosave() {
        let targetItemID = reviewBoundItemID
        let snapshot = reviewDraft
        reviewAutosaveTask?.cancel()
        reviewAutosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            persistReview(itemID: targetItemID, text: snapshot, notify: true)
            reviewAutosaveTask = nil
        }
    }

    private func flushReviewDraft(notify: Bool) {
        reviewAutosaveTask?.cancel()
        reviewAutosaveTask = nil
        persistReview(itemID: reviewBoundItemID, text: reviewDraft, notify: notify)
    }

    private func persistReview(itemID: String, text: String, notify: Bool) {
        guard !itemID.isEmpty else { return }
        guard let context = item.modelContext else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text

        if item.itemID == itemID {
            guard item.review != normalized else { return }
            item.review = normalized
            if notify {
                ClipItemStore.saveAndNotifyContent(context)
            } else {
                try? context.save()
            }
            return
        }

        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.itemID == itemID })
        guard let boundItem = try? context.fetch(descriptor).first else { return }
        guard boundItem.review != normalized else { return }
        boundItem.review = normalized
        if notify {
            ClipItemStore.saveAndNotifyContent(context)
        } else {
            try? context.save()
        }
    }
}
