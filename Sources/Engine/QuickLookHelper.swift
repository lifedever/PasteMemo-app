import AppKit
import Quartz

@MainActor
final class QuickLookHelper: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookHelper()

    private var previewURL: URL?
    private var tempFiles: [URL] = []

    private override init() { super.init() }

    func preview(item: ClipItem) {
        let url = prepareURL(for: item)
        guard let url else { return }

        previewURL = url

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self

        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func toggle(item: ClipItem) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            cleanupTempFiles()
        } else {
            preview(item: item)
        }
    }

    func canOpenInPreview(item: ClipItem) -> Bool {
        prepareURL(for: item) != nil
    }

    func openInPreviewApp(item: ClipItem) {
        guard let url = prepareURL(for: item) else { return }
        previewURL = url

        if let previewAppURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: previewAppURL, configuration: configuration) { _, error in
                if error != nil {
                    NSWorkspace.shared.open(url)
                }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func prepareURL(for item: ClipItem) -> URL? {
        switch item.contentType {
        case .file, .video, .audio, .document, .archive, .application:
            let path = item.content.components(separatedBy: "\n").first ?? ""
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: path) ? url : nil

        case .image:
            if item.content != "[Image]" {
                let path = item.content.components(separatedBy: "\n").first ?? ""
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
            guard let data = item.imageBytesForExport() ?? item.imageData else { return nil }
            return writeTempImageFile(data: data, itemID: item.itemID)

        case .link:
            if let data = item.imageData, !data.isEmpty {
                return writeTempImageFile(data: data, itemID: item.itemID)
            }
            if DataImageURI.isBase64DataImageURI(item.content),
               let data = DataImageURI.decodedImageData(from: item.content) {
                return writeTempImageFile(data: data, itemID: item.itemID)
            }
            return nil

        default:
            let data = item.content.data(using: .utf8) ?? Data()
            return writeTempFile(data: data, name: "preview-\(item.itemID).txt")
        }
    }

    /// Writes clipboard image bytes using the correct extension (TIFF/HEIC/JPEG/…).
    /// Hard-coding `.png` breaks macOS screenshots, which are often TIFF on the pasteboard.
    private func writeTempImageFile(data: Data, itemID: String) -> URL? {
        let ext = ClipboardManager.sniffImageExtension(from: data)
        return writeTempFile(data: data, name: "preview-\(itemID).\(ext)")
    }

    private func writeTempFile(data: Data, name: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PasteMemo-QL")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try data.write(to: url)
            if !tempFiles.contains(url) {
                tempFiles.append(url)
            }
            return url
        } catch {
            return nil
        }
    }

    private func cleanupTempFiles() {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles.removeAll()
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            previewURL as? NSURL
        }
    }
}
