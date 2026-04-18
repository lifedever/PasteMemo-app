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
        pasteboardSnapshot: Data? = nil
    ) {
        self.id = UUID()
        self.content = content
        self.imageData = imageData
        self.contentKind = contentKind
        self.state = .pending
        self.pasteboardSnapshot = pasteboardSnapshot
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
        // Pure image (screenshot / web-copied PNG with no file path)
        if clip.contentType == .image, clip.content == "[Image]", let data = clip.imageData {
            return RelayItem(
                content: clip.content,
                imageData: data,
                contentKind: .image,
                pasteboardSnapshot: clip.pasteboardSnapshot
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
                pasteboardSnapshot: clip.pasteboardSnapshot
            )
        }

        // Text / code / link / color / etc.
        let trimmed = clip.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RelayItem(
            content: trimmed,
            imageData: clip.imageData,
            contentKind: .text,
            pasteboardSnapshot: clip.pasteboardSnapshot
        )
    }
}
