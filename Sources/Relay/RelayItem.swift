import Foundation

struct RelayItem: Identifiable {
    let id: UUID
    var content: String
    var imageData: Data?
    var contentKind: ContentKind
    var state: ItemState
    /// Full pasteboard snapshot captured at copy time. Replayed verbatim on paste so
    /// targets like Word / Notes / Pages pick their preferred UTI — matches native
    /// Cmd+C → Cmd+V behaviour for rich-text (RTFD/HTML) content.
    var pasteboardSnapshot: Data?
    /// Bundle identifier of the app the clip was copied from (e.g. `com.microsoft.Word`).
    /// Carried from `ClipItem.sourceAppBundleID` so relay-paste rule evaluation can honor
    /// `sourceApp` conditions. `nil` when PasteMemo didn't know the source at capture time.
    var sourceAppBundleID: String?

    enum ContentKind {
        case text
        case image
        case file
    }

    enum ItemState {
        case pending, current, done, skipped
    }

    var isImage: Bool { contentKind == .image }
    var isFile: Bool { contentKind == .file }

    /// Image bytes intended for paste/embed. For file-backed clips re-reads the
    /// original from disk so paste delivers full resolution rather than the
    /// thumbnail captured into `imageData` at copy time.
    func imageBytesForExport() -> Data? {
        let firstPath = content.components(separatedBy: "\n").first(where: { !$0.isEmpty })
        if let path = firstPath,
           FileManager.default.fileExists(atPath: path),
           let original = ClipboardManager.loadOriginalImageData(at: path) {
            return original
        }
        return imageData
    }

    /// For file items, show filename(s); for others, show content
    var displayName: String {
        guard isFile else { return content }
        let paths = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        if paths.count == 1 {
            return URL(fileURLWithPath: paths[0]).lastPathComponent
        }
        let first = URL(fileURLWithPath: paths[0]).lastPathComponent
        return "\(first) etc. \(paths.count) files"
    }

    init(
        content: String,
        imageData: Data? = nil,
        contentKind: ContentKind = .text,
        pasteboardSnapshot: Data? = nil,
        sourceAppBundleID: String? = nil
    ) {
        self.id = UUID()
        self.content = content
        self.imageData = imageData
        self.contentKind = contentKind
        self.state = .pending
        self.pasteboardSnapshot = pasteboardSnapshot
        self.sourceAppBundleID = sourceAppBundleID
    }

    /// Factory converting a ClipItem into a RelayItem. Returns nil for empty content.
    ///
    /// - Pure-image clips (`content == "[Image]"`) → `.image` kind; paster writes NSImage.
    /// - Any file-based clip (image / file / video / audio / document / archive / application
    ///   with content holding file path(s)) → `.file` kind; paster writes file URLs plus an
    ///   inline NSImage when `imageData` is available. Targets like Finder and Messages
    ///   receive real files; text targets fall back to the filename string.
    /// - Everything else → `.text` kind.
    @MainActor
    static func from(_ clip: ClipItem) -> RelayItem? {
        // Pure image (screenshot / web-copied PNG with no file path). Carry the verbatim
        // ORIGINAL (the receiving device has no access to our local cache file), never the
        // small thumbnail stored in `clip.imageData`.
        if clip.contentType == .image, clip.content == "[Image]", let data = clip.imageBytesForExport() {
            return RelayItem(
                content: clip.content,
                imageData: data,
                contentKind: .image,
                pasteboardSnapshot: clip.pasteboardSnapshot,
                sourceAppBundleID: clip.sourceAppBundleID
            )
        }

        // File-based clips (Finder-copied anything: PDF / docx / zip / video / audio /
        // app bundle, or an image file with a path on disk). All paste as real files.
        if clip.contentType.isFileBased {
            let trimmedPath = clip.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else { return nil }
            return RelayItem(
                content: trimmedPath,
                imageData: clip.imageData,  // nil for non-image files, thumbnail for single image file
                contentKind: .file,
                pasteboardSnapshot: clip.pasteboardSnapshot,
                sourceAppBundleID: clip.sourceAppBundleID
            )
        }

        // Text / code / link / color / etc.
        let trimmed = clip.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Hard cap at 2MB for text content. Pathological pastes (entire terminal buffer,
        // giant log dump) otherwise freeze UI + engine. Images/files are unaffected —
        // they go through the branches above with no content truncation.
        let MAX_TEXT_BYTES = 2 * 1024 * 1024
        let safeContent: String
        if trimmed.utf8.count > MAX_TEXT_BYTES {
            // Truncate by character count since utf8 byte index can slice a scalar.
            // 2M characters is a comfortable approximation of 2MB for most scripts.
            let approxCharCap = 2_000_000
            let head = String(trimmed.prefix(approxCharCap))
            safeContent = head + "\n" + L10n.tr("relay.content.truncated")
        } else {
            safeContent = trimmed
        }
        return RelayItem(
            content: safeContent,
            imageData: clip.imageData,
            contentKind: .text,
            pasteboardSnapshot: clip.pasteboardSnapshot,
            sourceAppBundleID: clip.sourceAppBundleID
        )
    }
}
