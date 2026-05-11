import Foundation
import Testing
@testable import PasteMemo

@Suite("copyImageFileToFolder symlink handling")
struct CopyImageFileToFolderTests {
    @Test("follows symlinks instead of duplicating the link node (Telegram .jpg → real file)")
    func followsSymlink() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Mirror Telegram's group-container layout: real bytes live at an
        // extension-less file, and a `.jpg` symlink points to them. macOS
        // shows the symlink "size" as the length of the target path string
        // (~100s of bytes), which is what users see as a 174-byte image.
        let realFileURL = tempDir.appendingPathComponent("telegram-cloud-photo-w")
        let symlinkURL = tempDir.appendingPathComponent("telegram-cloud-photo-w.jpg")
        let destFolder = tempDir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)

        let realBytes = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        try realBytes.write(to: realFileURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realFileURL)

        let savedURL = try #require(
            ClipboardManager.copyImageFileToFolder(sourceURL: symlinkURL, folder: destFolder)
        )

        // The destination must be a regular file holding the image bytes,
        // not a symlink. This is what failed before the fix: copyItem
        // produces a symlink node containing only the target path string.
        let savedAttrs = try FileManager.default.attributesOfItem(atPath: savedURL.path)
        #expect((savedAttrs[.type] as? FileAttributeType) == .typeRegular)

        let savedBytes = try Data(contentsOf: savedURL)
        #expect(savedBytes == realBytes)
        #expect(savedBytes.count == realBytes.count)

        // Filename should match the user-visible source name (`*.jpg`),
        // not the symlink's target name (which lacks the extension).
        #expect(savedURL.lastPathComponent == "telegram-cloud-photo-w.jpg")
    }

    @Test("regular files still byte-copy unchanged")
    func regularFileCopyUnchanged() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("photo.png")
        let destFolder = tempDir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)

        let bytes = Data((0..<8192).map { _ in UInt8.random(in: 0...255) })
        try bytes.write(to: sourceURL)

        let savedURL = try #require(
            ClipboardManager.copyImageFileToFolder(sourceURL: sourceURL, folder: destFolder)
        )

        let savedAttrs = try FileManager.default.attributesOfItem(atPath: savedURL.path)
        #expect((savedAttrs[.type] as? FileAttributeType) == .typeRegular)
        let savedBytes = try Data(contentsOf: savedURL)
        #expect(savedBytes == bytes)
        #expect(savedURL.lastPathComponent == "photo.png")
    }

    @Test("name collisions resolve to ' 1', ' 2' suffixes")
    func nameCollisionResolves() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = tempDir.appendingPathComponent("photo.jpg")
        let destFolder = tempDir.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: sourceURL)

        let first = try #require(ClipboardManager.copyImageFileToFolder(sourceURL: sourceURL, folder: destFolder))
        let second = try #require(ClipboardManager.copyImageFileToFolder(sourceURL: sourceURL, folder: destFolder))

        #expect(first.lastPathComponent == "photo.jpg")
        #expect(second.lastPathComponent == "photo 1.jpg")
    }
}
