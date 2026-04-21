import SwiftUI
import AppKit
import AVFoundation

struct ClipDetailView: View {
    let item: ClipItem
    let clipboardManager: ClipboardManager
    @Environment(\.modelContext) private var modelContext

    @State private var isEditing = false
    @State private var editingContent = ""
    @State private var isOCRExpanded = false
    @AppStorage(OCRTaskCoordinator.enableOCRKey) private var ocrEnabled = true

    private var isEditableType: Bool {
        (item.contentType == .text || item.contentType == .code)
            && item.richTextData == nil
    }

    @ViewBuilder
    var body: some View {
        if item.isDeleted { EmptyView() } else {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()

            if item.isSensitive, !isEditing {
                SensitiveMask {
                    contentArea
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.04))
            } else {
                contentArea
                    .background(Color.primary.opacity(0.04))
            }

            Divider().opacity(0.3)

            if item.contentType == .image, ocrEnabled {
                ocrCard
                Divider().opacity(0.3)
            }

            propertiesCard
        }
        .onChange(of: item.persistentModelID) {
            if isEditing { cancelEdit() }
            isOCRExpanded = false
        }
        } // isDeleted guard
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if isEditing {
            editableTextPreview
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if item.contentType == .link {
            VStack(alignment: .leading, spacing: 0) {
                contentPreview
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if item.contentType == .image, item.imageData != nil {
            VStack { contentPreview }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.contentType == .video, !item.content.contains("\n") {
            VStack { contentPreview }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.contentType == .audio, !item.content.contains("\n") {
            audioPreview
        } else if item.contentType == .code {
            CodePreviewView(code: item.content, language: item.resolvedCodeLanguage, insets: NSSize(width: 16, height: 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.contentType == .text {
            contentPreview
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if item.contentType == .color {
            contentPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.contentType == .phone {
            phonePreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isSingleFile {
            SingleFilePreview(
                path: item.content.trimmingCharacters(in: .whitespacesAndNewlines),
                iconSize: 64,
                nameFont: .system(size: 15, weight: .medium)
            )
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { contentPreview }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(detailTitle, systemImage: item.contentType.icon)
                .font(.headline)
                .lineLimit(2)

            HStack {
                Spacer()
                copyButton
                if isEditableType { editButtons }
                sensitiveButton
                pinButton
                if !item.content.isEmpty { relayButton }
                deleteButton
            }
        }
    }

    private var copyButton: some View {
        Button {
            clipboardManager.writeToPasteboard(item)
            NotificationCenter.default.post(
                name: Notification.Name("copyItemFromDetail"),
                object: nil
            )
        } label: {
            Label(L10n.tr("action.copy"), systemImage: "doc.on.doc")
                .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var sensitiveButton: some View {
        Button {
            item.isSensitive.toggle()
            ClipItemStore.saveAndNotify(modelContext)
        } label: {
            Label(
                item.isSensitive ? L10n.tr("sensitive.unmarkSensitive") : L10n.tr("sensitive.markSensitive"),
                systemImage: item.isSensitive ? "lock.shield" : "lock.shield.fill"
            )
            .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var pinButton: some View {
        Button {
            item.isPinned.toggle()
            ClipItemStore.saveAndNotify(modelContext)
            NotificationCenter.default.post(name: Notification.Name("clearSelection"), object: nil)
        } label: {
            Label(
                item.isPinned ? L10n.tr("action.unpin") : L10n.tr("action.pin"),
                systemImage: item.isPinned ? "pin.slash" : "pin"
            )
            .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var relayButton: some View {
        Button {
            RelayManager.shared.addToQueue(clipItems: [item])
        } label: {
            Label(L10n.tr("relay.addToQueue"), systemImage: "arrow.right.arrow.left")
                .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            NotificationCenter.default.post(name: Notification.Name("deleteSelectedFromDetail"), object: nil)
        } label: {
            Label(L10n.tr("cmd.delete"), systemImage: "trash")
                .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var editButtons: some View {
        if isEditing {
            Button { saveEdit() } label: {
                Label(L10n.tr("action.save"), systemImage: "square.and.arrow.down")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button { cancelEdit() } label: {
                Label(L10n.tr("action.cancel"), systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button { enterEditMode() } label: {
                Label(L10n.tr("action.edit"), systemImage: "pencil")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func enterEditMode() {
        editingContent = item.content
        isEditing = true
    }

    private func cancelEdit() {
        isEditing = false
        editingContent = ""
    }

    private func saveEdit() {
        item.content = editingContent
        item.displayTitle = ClipItem.buildTitle(
            content: item.content,
            contentType: item.contentType,
            imageData: item.imageData
        )
        item.isSensitive = SensitiveDetector.isSensitive(
            content: item.content,
            sourceAppBundleID: nil,
            contentType: item.contentType
        )
        isEditing = false
        textRefreshID = UUID()
    }

    // MARK: - Content Preview

    @ViewBuilder
    private var contentPreview: some View {
        if item.contentType == .image, item.content != "[Image]", item.imageData == nil {
            filePreview
        } else {
            contentPreviewByType
        }
    }

    @ViewBuilder
    private var contentPreviewByType: some View {
        switch item.contentType {
        case .image:
            imagePreview
        case .link:
            linkPreview
        case .video:
            if isSingleVideo { videoPreview } else { filePreview }
        case .audio:
            if isSingleFile { audioPreview } else { filePreview }
        case .file, .document, .archive, .application:
            filePreview
        case .color:
            colorPreview
        default:
            textPreviewContent
        }
    }

    private var isSingleFile: Bool {
        item.contentType.isFileBased && item.contentType != .image && !item.content.contains("\n")
    }

    private var detailTitle: String {
        guard item.contentType.isFileBased, item.contentType != .image else { return item.contentType.label }
        let paths = item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let first = paths.first else { return item.contentType.label }
        let name = URL(fileURLWithPath: first).lastPathComponent
        if paths.count > 1 {
            return "\(name) +\(paths.count - 1)"
        }
        return name
    }

    private var isSingleVideo: Bool {
        item.contentType == .video && !item.content.contains("\n")
    }

    private var audioPreview: some View {
        AudioPlayerView(
            path: item.content.trimmingCharacters(in: .whitespacesAndNewlines),
            iconSize: 64,
            nameFont: .system(size: 15, weight: .medium)
        )
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var videoPreview: some View {
        VideoThumbnailView(path: item.content.trimmingCharacters(in: .whitespacesAndNewlines))
            .frame(maxHeight: 400)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var editableTextPreview: some View {
        NativeTextView(
            text: editingContent,
            isEditable: true,
            onTextChange: { editingContent = $0 }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var textRefreshID = UUID()

    private var textPreviewContent: some View {
        NativeTextView(
            text: item.content,
            richTextData: item.richTextData,
            richTextType: item.richTextType,
            itemID: item.itemID
        )
            .id("\(item.persistentModelID)-\(textRefreshID)-\(item.content.hashValue)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var colorDisplayFormat: ColorFormat?
    @State private var pickerColor: Color = .white

    @ViewBuilder
    private var colorPreview: some View {
        if let parsed = ColorConverter.parse(item.content) {
            let displayFmt = colorDisplayFormat ?? parsed.originalFormat
            VStack(spacing: 16) {
                Circle()
                    .fill(Color(nsColor: parsed.nsColor))
                    .frame(width: 120, height: 120)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    .shadow(color: Color(nsColor: parsed.nsColor).opacity(0.4), radius: 16, y: 6)
                    .onTapGesture {
                        NSApp.activate(ignoringOtherApps: true)
                        let panel = NSColorPanel.shared
                        panel.color = parsed.nsColor
                        panel.setTarget(nil)
                        panel.level = .floating
                        panel.orderFrontRegardless()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSColorPanel.colorDidChangeNotification)) { _ in
                        let nsC = NSColorPanel.shared.color.usingColorSpace(.sRGB) ?? NSColorPanel.shared.color
                        let updated = ColorConverter.from(nsColor: nsC)
                        let fmt = colorDisplayFormat ?? parsed.originalFormat
                        item.content = updated.formatted(fmt)
                        item.displayTitle = item.content
                    }

                Text(parsed.formatted(displayFmt))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    ForEach(ColorFormat.allCases, id: \.self) { fmt in
                        Button {
                            colorDisplayFormat = fmt
                            item.content = parsed.formatted(fmt)
                            item.displayTitle = item.content
                        } label: {
                            Text(fmt.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { pickerColor = Color(nsColor: parsed.nsColor) }
            .onChange(of: item.id) {
                colorDisplayFormat = nil
                if let p = ColorConverter.parse(item.content) {
                    pickerColor = Color(nsColor: p.nsColor)
                }
            }
        }
    }

    @ViewBuilder
    private var imagePreview: some View {
        AsyncPreviewImageView(
            data: item.imageData,
            cacheKey: item.itemID,
            maxPixelSize: 1400,
            cornerRadius: 8
        )
    }

    @AppStorage("webPreviewEnabled") private var webPreviewEnabled = true
    @AppStorage("imageLinkPreviewEnabled") private var imageLinkPreviewEnabled = true

    @ViewBuilder
    private var linkPreview: some View {
        if let url = URL(string: item.content.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if (imageLinkPreviewEnabled && LinkMetadataFetcher.isImageURL(item.content)) || webPreviewEnabled {
                linkWebPreview(url: url)
            } else {
                linkStaticPreview(url: url)
            }
        }
    }

    @State private var isLinkButtonHovered = false

    @ViewBuilder
    private func linkStaticPreview(url: URL) -> some View {
        VStack(spacing: 12) {
            if let img = validFavicon(minSize: 32) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, height: 64)
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
        .padding(.horizontal, 20)
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

    @ViewBuilder
    private func linkWebPreview(url: URL) -> some View {
        VStack(spacing: 0) {
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
                Text(item.content)
                    .font(.system(size: 13))
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
            .padding(.bottom, 10)

            WebPreviewView(url: url)
                .id(url)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var filePreview: some View {
        let paths = item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
        if paths.count == 1, let path = paths.first {
            SingleFilePreview(path: path, iconSize: 64, nameFont: .system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                    FileRow(path: path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Phone Preview

    private var phonePreview: some View {
        let number = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 24) {
            Image(systemName: "phone.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.mint)

            Text(number)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .textSelection(.enabled)

            HStack(spacing: 20) {
                detailPhoneButton(
                    icon: "phone.fill",
                    label: L10n.tr("phone.call"),
                    color: .green
                ) {
                    if let url = URL(string: "tel:\(number)") {
                        NSWorkspace.shared.open(url)
                    }
                }

                detailPhoneButton(
                    icon: "message.fill",
                    label: L10n.tr("phone.message"),
                    color: .blue
                ) {
                    if let url = URL(string: "sms:\(number)") {
                        NSWorkspace.shared.open(url)
                    }
                }

                detailPhoneButton(
                    icon: "doc.on.doc.fill",
                    label: L10n.tr("phone.copy"),
                    color: .orange
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(number, forType: .string)
                }
            }
        }
    }

    private func detailPhoneButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
                    .frame(width: 48, height: 48)
                    .background(color.opacity(0.1), in: Circle())
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Properties Card

    private var propertiesCard: some View {
        ClipPropertiesView(item: item, fontSize: 12) { path in
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.clear)
    }

    private var ocrCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("OCR")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                Text(ocrStatusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let text = item.ocrText, !text.isEmpty {
                    Button(L10n.tr("detail.ocr.copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if OCRTaskCoordinator.shared.canRetry(item: item) {
                    Button(L10n.tr("detail.ocr.retry")) {
                        OCRTaskCoordinator.shared.retry(itemID: item.itemID)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            Group {
                if let text = item.ocrText, !text.isEmpty {
                    ScrollView {
                        Text(displayedOCRText)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                    }
                    .frame(minHeight: 56, maxHeight: isOCRExpanded ? 220 : 120)
                } else {
                    Text(ocrEmptyText)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    private var ocrStatusText: String {
        switch item.resolvedOCRStatus {
        case .pending:
            return L10n.tr("detail.ocr.pending")
        case .processing:
            return L10n.tr("detail.ocr.processing")
        case .done:
            return L10n.tr("detail.ocr.ready")
        case .failed:
            return item.ocrErrorMessage ?? L10n.tr("detail.ocr.failed")
        case .skipped:
            return item.ocrText?.isEmpty == false ? L10n.tr("detail.ocr.ready") : L10n.tr("detail.ocr.empty")
        }
    }

    private var ocrEmptyText: String {
        switch item.resolvedOCRStatus {
        case .failed:
            return L10n.tr("detail.ocr.failed")
        case .processing, .pending:
            return L10n.tr("detail.ocr.processing")
        case .done, .skipped:
            return L10n.tr("detail.ocr.empty")
        }
    }

    private var displayedOCRText: String {
        guard let text = item.ocrText else { return "" }
        guard !isOCRExpanded else { return text }
        let limit = 1600
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "\n…"
    }

    private var shouldShowOCRExpandToggle: Bool {
        guard let text = item.ocrText else { return false }
        return text.count > 1600
    }
}

// MARK: - File Row with Hover

struct FileRow: View {
    let path: String
    var onOpenInFinder: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: systemIcon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if isHovered {
                Button {
                    onOpenInFinder?()
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
                } label: {
                    HStack(spacing: 3) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app"))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                        Text(L10n.tr("detail.openInFinder"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Single File Preview (Centered)

struct SingleFilePreview: View {
    let path: String
    var iconSize: CGFloat = 64
    var nameFont: Font = .system(size: 15, weight: .medium)
    var onOpenInFinder: (() -> Void)?
    @State private var isButtonHovered = false

    private var finderAppIcon: NSImage {
        NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: systemIcon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)

            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(nameFont)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            Text(path)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.horizontal, 24)

            Button {
                onOpenInFinder?()
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
            } label: {
                HStack(spacing: 4) {
                    Image(nsImage: finderAppIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                    Text(L10n.tr("detail.openInFinder"))
                        .font(.system(size: 12))
                }
                .foregroundStyle(isButtonHovered ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .onHover { isButtonHovered = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
