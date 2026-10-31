import Foundation
import Testing
@testable import PasteMemo

/// Multi-paste into WeChat sends images as their original files; a selection that's all files
/// goes out in one paste, in order.
@Suite("File URL multi-paste")
@MainActor
struct FileURLPasteTests {
    private func tempFile(_ ext: String) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("fup-\(UUID().uuidString).\(ext)").path
        try Data([0x00]).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("images and files, in selection order — raw images by their saved original")
    func allFiles() throws {
        let original = try tempFile("heic"), photo = try tempFile("jpg"), doc = try tempFile("docx")
        defer { [original, photo, doc].forEach { try? FileManager.default.removeItem(atPath: $0) } }
        let items = [
            ClipItem(content: "[Image]", contentType: .image, originalImageFilePath: original),
            ClipItem(content: photo + "\n" + doc, contentType: .file),
        ]
        #expect(FileURLPaste.filePaths(for: items) == [original, photo, doc])
    }

    @Test("anything that isn't a file on disk rules out the single paste")
    func notAllFiles() throws {
        let photo = try tempFile("jpg")
        defer { try? FileManager.default.removeItem(atPath: photo) }
        #expect(FileURLPaste.filePaths(for: [ClipItem(content: photo, contentType: .image), ClipItem(content: "hi")]) == nil)
        #expect(FileURLPaste.filePaths(for: [ClipItem(content: "[Image]", contentType: .image, imageData: Data([1]))]) == nil)
        #expect(FileURLPaste.filePaths(for: [ClipItem(content: "/nonexistent/a.jpg", contentType: .image)]) == nil)
    }
}
