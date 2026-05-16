import AppKit
import UniformTypeIdentifiers

/// Presents Save / Choose Folder panels to write a clip's payload to disk.
@MainActor
enum ClipItemSaveToFilePresenter {

    static func canSaveAsFile(_ item: ClipItem) -> Bool {
        guard !item.isDeleted else { return false }
        if !resolvedExistingPaths(for: item).isEmpty { return true }
        if item.imageBytesForExport() != nil { return true }
        let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "[Image]", item.imageBytesForExport() == nil { return false }
        return true
    }

    static func beginSave(_ item: ClipItem) {
        guard canSaveAsFile(item) else { return }
        NSApp.activate(ignoringOtherApps: true)

        let paths = resolvedExistingPaths(for: item)
        if paths.count > 1 {
            presentChooseFolderAndCopy(paths: paths)
            return
        }
        if paths.count == 1 {
            presentSaveCopy(ofFileAt: paths[0], item: item)
            return
        }

        if shouldPreferImageExport(for: item), let data = item.imageBytesForExport() {
            presentSaveImage(data: data, item: item)
            return
        }

        presentSaveText(item)
    }

    // MARK: - Path resolution

    private static func resolvedExistingPaths(for item: ClipItem) -> [String] {
        var collected: [String] = []
        if item.contentType.isFileBased && item.content != "[Image]" {
            collected.append(contentsOf: item.content.components(separatedBy: "\n"))
        }
        collected.append(contentsOf: item.resolvedFilePaths)
        var seen = Set<String>()
        var out: [String] = []
        for raw in collected {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty, FileManager.default.fileExists(atPath: p), !seen.contains(p) else { continue }
            seen.insert(p)
            out.append(p)
        }
        return out
    }

    private static func shouldPreferImageExport(for item: ClipItem) -> Bool {
        guard item.imageBytesForExport() != nil else { return false }
        guard resolvedExistingPaths(for: item).isEmpty else { return false }

        switch item.contentType {
        case .image:
            return true
        case .mixed:
            let trimmed = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == "[Image]"
        default:
            return false
        }
    }

    // MARK: - Panels

    private static func presentSaveCopy(ofFileAt path: String, item: ClipItem) {
        let src = URL(fileURLWithPath: path)
        let panel = NSSavePanel()
        panel.title = L10n.tr("cmd.saveAsFile")
        panel.prompt = L10n.tr("saveAs.save")
        panel.canCreateDirectories = true
        let ext = src.pathExtension.isEmpty ? "txt" : src.pathExtension
        panel.nameFieldStringValue = defaultFileName(for: item, ext: ext)
        if !src.pathExtension.isEmpty, let ut = UTType(filenameExtension: src.pathExtension) {
            panel.allowedContentTypes = [ut]
        }
        panel.directoryURL = src.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        copyFileReplacing(from: src, to: dest)
    }

    private static func presentChooseFolderAndCopy(paths: [String]) {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("cmd.saveAsFile")
        panel.prompt = L10n.tr("saveAs.chooseFolderPrompt")
        panel.message = L10n.tr("saveAs.chooseFolderMessage", paths.count)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destDir = panel.url else { return }

        let fm = FileManager.default
        var ok = 0
        for path in paths {
            let src = URL(fileURLWithPath: path)
            let name = src.lastPathComponent
            let dest = uniqueDestinationURL(in: destDir, preferredName: name, sourceURL: src)
            do {
                try fm.copyItem(at: src, to: dest)
                ok += 1
            } catch { continue }
        }

        if ok == paths.count {
            ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("saveAs.exportedCount", ok), icon: .success))
        } else if ok > 0 {
            ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("saveAs.exportedPartial", ok, paths.count), icon: .info))
        } else {
            toastFailed()
        }
    }

    private static func uniqueDestinationURL(in folder: URL, preferredName: String, sourceURL: URL) -> URL {
        let fm = FileManager.default
        var dest = folder.appendingPathComponent(preferredName)
        guard fm.fileExists(atPath: dest.path) else { return dest }

        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            let stem = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            dest = folder.appendingPathComponent(stem)
            n += 1
        }
        return dest
    }

    private static func presentSaveImage(data: Data, item: ClipItem) {
        let panel = NSSavePanel()
        panel.title = L10n.tr("cmd.saveAsFile")
        panel.prompt = L10n.tr("saveAs.save")
        panel.canCreateDirectories = true
        let ext = imageFileExtension(for: data)
        if let ut = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [ut]
        }
        panel.nameFieldStringValue = defaultFileName(for: item, ext: ext)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try data.write(to: dest, options: .atomic)
            toastSaved(dest)
        } catch {
            toastFailed()
        }
    }

    private static func presentSaveText(_ item: ClipItem) {
        let panel = NSSavePanel()
        panel.title = L10n.tr("cmd.saveAsFile")
        panel.prompt = L10n.tr("saveAs.save")
        panel.canCreateDirectories = true
        let ext = item.contentType == .code ? item.resolvedFileExtension : "txt"
        if let ut = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [ut]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        panel.nameFieldStringValue = defaultFileName(for: item, ext: ext)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        guard let encoded = item.content.data(using: .utf8) else {
            toastFailed()
            return
        }
        do {
            try encoded.write(to: dest, options: .atomic)
            toastSaved(dest)
        } catch {
            toastFailed()
        }
    }

    // MARK: - File ops & helpers

    private static func copyFileReplacing(from src: URL, to dest: URL) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: src, to: dest)
            toastSaved(dest)
        } catch {
            toastFailed()
        }
    }

    private static func toastSaved(_ url: URL) {
        ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("saveAs.saved", url.path), icon: .success))
    }

    private static func toastFailed() {
        ToastCenter.shared.show(ToastDescriptor(message: L10n.tr("saveAs.failed"), icon: .info))
    }

    private static func defaultFileName(for item: ClipItem, ext: String) -> String {
        let shortID = item.itemID.split(separator: "-", maxSplits: 1).first.map(String.init) ?? item.itemID
        return "pastememo_\(shortID).\(ext)"
    }

    private static func imageFileExtension(for data: Data) -> String {
        guard data.count >= 8 else { return "png" }
        if data.starts(with: Data([0xFF, 0xD8, 0xFF])) { return "jpg" }
        if data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) { return "png" }
        if data.starts(with: Data([0x47, 0x49, 0x46])) { return "gif" }
        // RIFF....WEBP
        let riff = Data([0x52, 0x49, 0x46, 0x46])
        let webp = Data([0x57, 0x45, 0x42, 0x50])
        if data.count >= 12,
           data.subdata(in: 0..<4) == riff,
           data.subdata(in: 8..<12) == webp {
            return "webp"
        }
        return "png"
    }
}
