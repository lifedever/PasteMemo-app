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

    /// Factory converting a ClipItem into a RelayItem. Returns nil for generic Finder file
    /// clips (non-image files — not a relay use-case) and empty content.
    ///
    /// Image handling:
    /// - Pure-image clips (`content == "[Image]"`, typically screenshots or web images with
    ///   no local file path) → `.image` kind; paster writes NSImage directly.
    /// - Finder-copied image files (content is a file path or newline-joined paths) →
    ///   `.file` kind with `imageData` preserved; paster writes file URLs + inline NSImage
    ///   together so targets like Word embed the image instead of falling back to the
    ///   filename string.
    @MainActor
    static func from(_ clip: ClipItem) -> RelayItem? {
        if clip.contentType == .file { return nil }

        if clip.contentType == .image {
            if clip.content == "[Image]", let data = clip.imageData {
                return RelayItem(
                    content: clip.content,
                    imageData: data,
                    contentKind: .image,
                    pasteboardSnapshot: clip.pasteboardSnapshot
                )
            }
            // File-backed image(s): treat as file so paster writes URLs + inline image.
            let trimmedPath = clip.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else { return nil }
            return RelayItem(
                content: trimmedPath,
                imageData: clip.imageData,
                contentKind: .file,
                pasteboardSnapshot: clip.pasteboardSnapshot
            )
        }

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
