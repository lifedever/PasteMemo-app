import Foundation
import SwiftData

/// Several clips merged into one that replaces them — ⌘K「合并」in the quick panel and the
/// main window's multi-select menu. Items come in display order and the merge keeps it: what
/// reads top to bottom in the list reads top to bottom in the result, same as a batch paste.
enum ClipMerge {
    static func canMerge(_ items: [ClipItem]) -> Bool {
        canMergeTexts(items) || canMergeFiles(items)
    }

    @MainActor
    @discardableResult
    static func merge(_ items: [ClipItem], in context: ModelContext) -> ClipItem? {
        if canMergeTexts(items) { return mergeTexts(items, in: context) }
        return mergeFiles(items, in: context)
    }

    // MARK: - Texts

    /// Text-like clips only: they join into one text.
    static func canMergeTexts(_ items: [ClipItem]) -> Bool {
        items.count > 1 && items.allSatisfy { $0.contentType.isMergeable }
    }

    /// Join the texts one per line into a new clip and delete the originals.
    @MainActor
    @discardableResult
    static func mergeTexts(_ items: [ClipItem], in context: ModelContext) -> ClipItem? {
        guard canMergeTexts(items) else { return nil }
        let merged = ClipItem(content: items.map(\.content).joined(separator: "\n"), contentType: .text)
        replace(items, with: merged, in: context)
        return merged
    }

    // MARK: - Images and files

    /// Images and files only: they become one multi-file clip, like several files copied in
    /// Finder. A raw image (screenshot, photo) needs its bytes to still be around.
    static func canMergeFiles(_ items: [ClipItem]) -> Bool {
        items.count > 1 && items.allSatisfy { item in
            switch item.contentType {
            case .image:
                !isRawImage(item) || item.sourceImageFileURL != nil || item.pasteableImageData != nil
            case .file, .video, .audio, .document, .archive, .application:
                true
            case .text, .link, .code, .color, .email, .phone, .mixed:
                false
            }
        }
    }

    /// Every file of every clip, in order, in one new clip; the originals are deleted.
    /// A raw image has no file of its own — its cached original belongs to the clip being
    /// deleted — so it's copied into a folder under `mergedFilesDirectory()` that the new clip
    /// owns, as `Image 1.<ext>`, `Image 2.<ext>`…
    @MainActor
    @discardableResult
    static func mergeFiles(_ items: [ClipItem], in context: ModelContext,
                           directory: URL? = mergedFilesDirectory()) -> ClipItem? {
        guard canMergeFiles(items), let directory else { return nil }
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = FileManager.default
        var paths: [String] = []
        var imageNumber = 0
        do {
            for item in items {
                guard isRawImage(item) else {
                    paths += item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
                    continue
                }
                imageNumber += 1
                if imageNumber == 1 {
                    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                if let source = item.sourceImageFileURL {
                    let destination = folder.appendingPathComponent("Image \(imageNumber).\(source.pathExtension)")
                    try fileManager.copyItem(at: source, to: destination)
                    paths.append(destination.path)
                } else if let data = item.imageBytesForExport() {
                    let ext = ClipboardManager.sniffImageExtension(from: data)
                    let destination = folder.appendingPathComponent("Image \(imageNumber).\(ext)")
                    try data.write(to: destination)
                    paths.append(destination.path)
                } else {
                    throw CocoaError(.fileNoSuchFile)
                }
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            return nil
        }

        let type = ClipboardManager.detectFileType(paths)
        let thumbnail = type == .image
            ? paths.first.flatMap { ClipboardManager.generateImageFileThumbnail(at: URL(fileURLWithPath: $0)) }
            : nil
        let merged = ClipItem(content: paths.joined(separator: "\n"), contentType: type, imageData: thumbnail)
        replace(items, with: merged, in: context)
        return merged
    }

    /// Where merged clips keep the files they own, one folder per merge.
    nonisolated static func mergedFilesDirectory() -> URL? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo"
        let dir = URL.applicationSupportDirectory
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Merged", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            return nil
        }
    }

    /// Delete merge folders no clip points into any more — their clip was deleted, expired, or
    /// never saved. Same idea as the originals cache sweep, and like it, run at launch: every
    /// way a clip goes away (undoable delete included) is covered without hooking each one.
    @MainActor
    static func sweepOrphanedMergeFolders(in context: ModelContext) {
        guard let directory = mergedFilesDirectory() else { return }
        let orphans = orphanedMergeFolders(in: context, directory: directory)
        guard !orphans.isEmpty else { return }
        Task.detached(priority: .utility) {
            for folder in orphans {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    @MainActor
    static func orphanedMergeFolders(in context: ModelContext, directory: URL) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        guard !folders.isEmpty else { return [] }
        // Only the rows that point in here — never materialise the whole table.
        let prefix = directory.path + "/"
        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.content.contains(prefix) })
        // A failed fetch can't tell what's referenced — delete nothing rather than everything.
        guard let contents = (try? context.fetch(descriptor))?.map(\.content) else { return [] }
        let referenced = Set(contents.flatMap { content in
            content.components(separatedBy: "\n").compactMap { path -> String? in
                guard path.hasPrefix(prefix) else { return nil }
                return path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
            }
        })
        return folders.filter { !referenced.contains($0.lastPathComponent) }
    }

    // MARK: -

    private static func isRawImage(_ item: ClipItem) -> Bool {
        item.contentType == .image && item.content == "[Image]"
    }

    /// Insert the merged clip and delete what it replaces. It's sensitive when any original
    /// was, so merging can't strip that off.
    @MainActor
    private static func replace(_ items: [ClipItem], with merged: ClipItem, in context: ModelContext) {
        context.insert(merged)
        if items.contains(where: \.isSensitive) {
            ActionExecutor.applyMetadata([.markSensitive], to: merged, context: context)
        }
        ClipItemStore.deleteAndNotify(items, from: context)
    }
}
