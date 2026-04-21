import Foundation
import SwiftData
import AppKit

enum OCRStatus: String, Codable, CaseIterable {
    case pending = "pending"
    case processing = "processing"
    case done = "done"
    case failed = "failed"
    case skipped = "skipped"
}

enum ClipContentType: String, Codable, CaseIterable {
    case text = "text"
    case link = "link"
    case image = "image"
    case file = "file"
    case video = "video"
    case audio = "audio"
    case document = "document"
    case archive = "archive"
    case application = "application"
    /// Multiple independent representations in one clip (e.g. text + image + files).
    /// Mirrors NSPasteboard multi-type semantics.
    case mixed = "mixed"
    // Legacy types — kept for database compatibility, hidden from UI
    case code = "code"
    case color = "color"
    case email = "email"
    case phone = "phone"

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = ClipContentType(rawValue: rawValue) ?? .text
    }

    static let defaultVisibleCases: [ClipContentType] = [
        .text, .code, .link, .image, .video, .audio, .document, .archive, .application, .color, .file
    ]

    /// Content types shown in the automation rule editor's content-type picker.
    /// Grouped by semantic bucket (text → media → files) and omits legacy types
    /// (`.email`, `.phone`) plus `.mixed` (too broad to target directly).
    static let ruleEditorVisibleCases: [ClipContentType] = [
        .text, .code, .link, .color,
        .image, .video, .audio,
        .document, .archive, .application, .file
    ]

    static var visibleCases: [ClipContentType] {
        guard let saved = UserDefaults.standard.stringArray(forKey: "typeOrder") else {
            return defaultVisibleCases
        }
        let mapped = saved.compactMap { ClipContentType(rawValue: $0) }
        // Append any new types not yet in saved order
        let missing = defaultVisibleCases.filter { !mapped.contains($0) }
        return mapped + missing
    }

    static func saveTypeOrder(_ types: [ClipContentType]) {
        UserDefaults.standard.set(types.map(\.rawValue), forKey: "typeOrder")
    }

    var isLegacy: Bool {
        switch self {
        case .email, .phone: return true
        default: return false
        }
    }

    /// File-based types: stored as file paths, rendered with file icons, support Finder operations
    var isFileBased: Bool {
        switch self {
        case .file, .video, .audio, .image, .document, .archive, .application: return true
        default: return false
        }
    }

    /// Text-like types that can be merged (excludes binary/file types)
    var isMergeable: Bool {
        switch self {
        case .text, .code, .link, .color, .email, .phone: return true
        case .image, .file, .video, .audio, .document, .archive, .application, .mixed: return false
        }
    }

    var icon: String {
        switch self {
        case .text: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.richtext"
        case .archive: return "doc.zipper"
        case .application: return "square.grid.2x2"
        case .color: return "paintpalette.fill"
        case .email: return "envelope"
        case .phone: return "phone"
        case .mixed: return "square.stack.3d.up.fill"
        }
    }

    @MainActor
    var label: String {
        switch self {
        case .text: return L10n.tr("type.text")
        case .code: return L10n.tr("type.code")
        case .link: return L10n.tr("type.link")
        case .image: return L10n.tr("type.image")
        case .file: return L10n.tr("type.other")
        case .video: return L10n.tr("type.video")
        case .audio: return L10n.tr("type.audio")
        case .document: return L10n.tr("type.document")
        case .archive: return L10n.tr("type.archive")
        case .application: return L10n.tr("type.application")
        case .color: return L10n.tr("type.color")
        case .email: return L10n.tr("type.email")
        case .phone: return L10n.tr("type.phone")
        case .mixed: return L10n.tr("type.mixed")
        }
    }
}

@Model
final class ClipItem {
    var itemID: String = UUID().uuidString
    var content: String
    /// Stored as raw String to avoid SwiftData enum deserialization crash on zombie objects.
    @Attribute(originalName: "contentType")
    var contentTypeRaw: String = ClipContentType.text.rawValue
    @Attribute(.externalStorage) var imageData: Data?
    var sourceApp: String?
    var sourceAppBundleID: String?
    var isFavorite: Bool
    var isPinned: Bool
    var isSensitive: Bool = false
    var createdAt: Date
    var lastUsedAt: Date
    var linkTitle: String?
    @Attribute(.externalStorage) var faviconData: Data?
    var displayTitle: String?
    /// Detected or user-overridden code language (only meaningful when contentType == .code)
    var codeLanguage: String?
    /// Rich text data (RTF or HTML format) for preserving original formatting
    @Attribute(.externalStorage) var richTextData: Data?
    /// Original rich text format type: "rtf" or "html"
    var richTextType: String?
    /// Newline-joined file paths when the clip contains file URLs alongside other representations
    /// (used primarily by `.mixed` items). Nil for legacy items and non-file-carrying clips.
    var filePaths: String?
    /// Full NSPasteboard snapshot (binary plist of `[String: Data]`) captured when the source
    /// exposed rich formatting. On paste, writing this back verbatim reproduces system-native
    /// paste behaviour — the target app (Word, Mail, browsers, etc.) picks whichever UTI it
    /// prefers. Nil for simple text/image/file clips where full-fidelity isn't needed.
    @Attribute(.externalStorage) var pasteboardSnapshot: Data?
    /// User-authored review/notes for this clip item. Nil/empty means no review.
    var review: String?
    var groupName: String?
    var ocrText: String?
    var ocrStatus: String = OCRStatus.skipped.rawValue
    var ocrUpdatedAt: Date?
    var ocrErrorMessage: String?
    var ocrVersion: Int = 1

    @MainActor
    init(
        content: String,
        contentType: ClipContentType = .text,
        imageData: Data? = nil,
        sourceApp: String? = nil,
        sourceAppBundleID: String? = nil,
        isFavorite: Bool = false,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        codeLanguage: String? = nil,
        richTextData: Data? = nil,
        richTextType: String? = nil,
        filePaths: String? = nil,
        pasteboardSnapshot: Data? = nil,
        review: String? = nil
    ) {
        self.content = content
        self.contentTypeRaw = contentType.rawValue
        self.imageData = imageData
        self.sourceApp = sourceApp
        self.sourceAppBundleID = sourceAppBundleID
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.codeLanguage = codeLanguage
        self.richTextData = richTextData
        self.richTextType = richTextType
        self.filePaths = filePaths
        self.pasteboardSnapshot = pasteboardSnapshot
        self.review = review
        self.displayTitle = Self.buildTitle(content: content, contentType: contentType, imageData: imageData, filePaths: filePaths)
        if (contentType == .image || contentType == .mixed), imageData != nil {
            self.ocrStatus = OCRStatus.pending.rawValue
        }
    }

    /// Parsed file paths from `filePaths` (newline-separated). Empty array if nil/empty.
    var resolvedFilePaths: [String] {
        guard let raw = filePaths, !raw.isEmpty else { return [] }
        return raw.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// Computed enum accessor — never crashes because contentTypeRaw is a plain String.
    var contentType: ClipContentType {
        get { ClipContentType(rawValue: contentTypeRaw) ?? .text }
        set { contentTypeRaw = newValue.rawValue }
    }

    var resolvedOCRStatus: OCRStatus {
        OCRStatus(rawValue: ocrStatus) ?? .skipped
    }

    func matchesOCROnly(searchText: String) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard contentType == .image else { return false }
        guard let ocrText, !ocrText.isEmpty else { return false }

        let query = trimmed.lowercased()
        // Check non-OCR fields first; short-circuit if any matches
        if content.localizedCaseInsensitiveContains(query) { return false }
        if let t = displayTitle, t.localizedCaseInsensitiveContains(query) { return false }
        if let t = linkTitle, t.localizedCaseInsensitiveContains(query) { return false }
        return ocrText.localizedCaseInsensitiveContains(query)
    }

    /// Resolved code language — uses stored override if available, otherwise auto-detects.
    var resolvedCodeLanguage: CodeLanguage? {
        if let raw = codeLanguage, let lang = CodeLanguage(rawValue: raw) {
            return lang
        }
        return nil
    }

    /// File extension for saving — based on language for code, "txt" for text.
    var resolvedFileExtension: String {
        guard contentType == .code else { return "txt" }
        if let lang = resolvedCodeLanguage { return lang.fileExtension }
        return "txt"
    }

    @MainActor
    static func buildTitle(content: String, contentType: ClipContentType, imageData: Data? = nil, filePaths: String? = nil) -> String {
        switch contentType {
        case .image:
            if content != "[Image]" {
                return URL(fileURLWithPath: content.components(separatedBy: "\n").first ?? "").lastPathComponent
            }
            if let data = imageData, let img = NSImage(data: data) {
                return "Image (\(Int(img.size.width))×\(Int(img.size.height)))"
            }
            return "[Image]"
        case .file, .video, .audio, .document, .archive, .application:
            let paths = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            let firstName = URL(fileURLWithPath: paths.first ?? "").lastPathComponent
            if paths.count > 1 {
                let suffix = L10n.tr("file.multiTitle", paths.count)
                let maxNameLen = 12
                let name = firstName.count > maxNameLen
                    ? String(firstName.prefix(maxNameLen)) + "..."
                    : firstName
                return name + suffix
            }
            return firstName
        case .link:
            return content
        case .color:
            return content
        case .mixed:
            // Prefer text content; fallback to first file name; finally [Mixed]
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedContent.isEmpty, trimmedContent != "[Image]" {
                let prefix = String(trimmedContent.prefix(200))
                let normalized = prefix.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }.joined(separator: " ")
                if !normalized.isEmpty { return normalized }
            }
            if let raw = filePaths, !raw.isEmpty {
                let paths = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
                if let first = paths.first {
                    return URL(fileURLWithPath: first).lastPathComponent
                }
            }
            return "[Mixed]"
        default:
            let prefix = String(content.prefix(200))
            let trimmed = prefix.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
            return trimmed.isEmpty ? "[Empty]" : trimmed
        }
    }
}
