import Foundation

/// Targets that take images best as files: pasting the original file shows the image inline,
/// side by side with its neighbours, the way pasting one at a time by hand does.
///
/// Measured on WeChat 4.2 (2026-10-31):
/// - Several file URLs in one write paste in order, side by side, like files copied in Finder;
///   images (JPEG, HEIC…) show as images. Text items written alongside them are dropped.
/// - Image data instead goes in as a TIFF it decodes asynchronously — a 12 MP photo is a 73 MB
///   TIFF, slow to appear, and a text pasted right after overtakes it.
/// - HTML can carry text and images in order in one write, but every image lands on a line of
///   its own whatever the markup — not how pasting by hand looks, so it isn't used.
/// - It reads the pasteboard the moment it changes, and every type at once, so a pasteboard
///   read is no sign that a paste was handled; its accessibility tree doesn't expose the input
///   box either. Pasting item by item can only be paced, not confirmed.
enum FileURLPaste {
    static let targetBundleIDs: Set<String> = ["com.tencent.xinWeChat"]

    /// Every item as files on disk, in order, or nil when one isn't a file — text, a mixed clip,
    /// an image with no saved original, a file that's gone. All files then go out in ONE paste:
    /// nothing to pace, nothing to race.
    @MainActor
    static func filePaths(for items: [ClipItem]) -> [String]? {
        var paths: [String] = []
        for item in items {
            switch item.contentType {
            case .image where item.content == "[Image]":
                guard let url = item.sourceImageFileURL else { return nil }
                paths.append(url.path)
            case .image, .file, .video, .audio, .document, .archive, .application:
                let itemPaths = item.content.components(separatedBy: "\n").filter { !$0.isEmpty }
                guard !itemPaths.isEmpty, itemPaths.allSatisfy(FileManager.default.fileExists) else { return nil }
                paths.append(contentsOf: itemPaths)
            case .text, .link, .code, .color, .email, .phone, .mixed:
                return nil
            }
        }
        return paths.isEmpty ? nil : paths
    }
}
