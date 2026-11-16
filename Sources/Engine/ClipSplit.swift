import Foundation
import SwiftData

/// One clip replaced by one clip per piece — ⌘K「拆分」, the reverse of `ClipMerge`.
/// Text is cut by `ClipSplitter`; a multi-file clip splits into one clip per file.
enum ClipSplit {

    /// What the split page offers for `item`: its text, or its files.
    enum Source: Equatable {
        case text(String)
        case files([String])
    }

    static func source(of item: ClipItem) -> Source? {
        guard !item.isGone else { return nil }
        if item.contentType.isMergeable {
            let text = item.content
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .text(text)
        }
        let paths = filePaths(of: item)
        return paths.count >= 2 ? .files(paths) : nil
    }

    static func canSplit(_ item: ClipItem) -> Bool {
        source(of: item) != nil
    }

    /// The files of a file-based clip, as stored (one path per line). A raw pasteboard
    /// image has no file — nothing to split.
    private static func filePaths(of item: ClipItem) -> [String] {
        switch item.contentType {
        case .file, .image, .video, .audio, .document, .archive, .application:
            guard item.content != "[Image]" else { return [] }
            return item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
        case .text, .link, .code, .color, .email, .phone, .mixed:
            return []
        }
    }

    /// Replace `item` with one clip per piece, top to bottom in the same order as the
    /// pieces. A piece that matches a clip already in the history brings that clip up
    /// instead of adding a second copy (the usual dedup rule). Undoable from the toast.
    /// Returns the clips now holding the pieces, in order.
    @MainActor
    @discardableResult
    static func apply(_ pieces: [String], replacing item: ClipItem, in context: ModelContext) -> [ClipItem] {
        guard pieces.count >= 2, let source = source(of: item) else { return [] }
        var result: [ClipItem] = []
        ClipUndoCoordinator.shared.perform(context: context) { change in
            // First piece newest: it lands on top and the rest follow in reading order.
            let now = Date()
            for (index, piece) in pieces.enumerated() {
                let stamp = now.addingTimeInterval(-Double(index) * 0.001)
                let candidate: ClipItem
                switch source {
                case .text: candidate = textClip(piece, from: item, at: stamp)
                case .files: candidate = fileClip(piece, from: item, at: stamp)
                }
                if let existing = ClipboardManager.shared.findExistingDuplicate(for: candidate, in: context),
                   existing !== item {
                    change.willModify(existing, includingBlobs: false)
                    existing.lastUsedAt = stamp
                    result.append(existing)
                } else {
                    change.insert(candidate)
                    result.append(candidate)
                }
            }
            change.delete([item])
            return L10n.tr("split.undo.toast", pieces.count)
        }
        return result
    }

    // MARK: -

    @MainActor
    private static func textClip(_ text: String, from source: ClipItem, at date: Date) -> ClipItem {
        let detected = ClipboardManager.shared.detectContentType(text)
        // A path typed in the middle of a note is still text, same as after an edit.
        let type: ClipContentType = detected.type == .file ? .text : detected.type
        let clip = ClipItem(
            content: text,
            contentType: type,
            sourceApp: source.sourceApp,
            sourceAppBundleID: source.sourceAppBundleID,
            createdAt: date,
            lastUsedAt: date,
            codeLanguage: type == .code ? detected.language : nil
        )
        inheritState(from: source, into: clip, sensitiveCheck: true)
        return clip
    }

    @MainActor
    private static func fileClip(_ path: String, from source: ClipItem, at date: Date) -> ClipItem {
        let type = ClipboardManager.detectFileType([path])
        let thumbnail = type == .image
            ? ClipboardManager.generateImageFileThumbnail(at: URL(fileURLWithPath: path))
            : nil
        let clip = ClipItem(
            content: path,
            contentType: type,
            imageData: thumbnail,
            sourceApp: source.sourceApp,
            sourceAppBundleID: source.sourceAppBundleID,
            createdAt: date,
            lastUsedAt: date
        )
        inheritState(from: source, into: clip, sensitiveCheck: false)
        return clip
    }

    /// Pieces stay in the clip's group and keep its sensitive mark (a split can't strip
    /// it off, same as a merge); a text piece is also checked on its own, like a copy.
    /// Not the pin: one pinned clip shouldn't turn into ten.
    @MainActor
    private static func inheritState(from source: ClipItem, into clip: ClipItem, sensitiveCheck: Bool) {
        clip.groupName = source.groupName
        clip.isSensitive = source.isSensitive || (sensitiveCheck && SensitiveDetector.isSensitive(
            content: clip.content,
            sourceAppBundleID: clip.sourceAppBundleID,
            contentType: clip.contentType
        ))
    }
}
