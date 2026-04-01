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

    private func prepareURL(for item: ClipItem) -> URL? {
        switch item.contentType {
        case .file, .video, .audio, .document, .archive, .application:
            let path = item.content.components(separatedBy: "\n").first ?? ""
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: path) ? url : nil

        case .image:
            if item.content != "[Image]" {
                let path = item.content.components(separatedBy: "\n").first ?? ""
                return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
            }
            guard let data = item.imageData else { return nil }
            return writeTempFile(data: data, name: "preview.png")

        case .link:
            return URL(string: item.content.trimmingCharacters(in: .whitespacesAndNewlines))

        default:
            let data = item.content.data(using: .utf8) ?? Data()
            return writeTempFile(data: data, name: "preview.txt")
        }
    }

    private func writeTempFile(data: Data, name: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PasteMemo-QL")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            tempFiles.append(url)
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
