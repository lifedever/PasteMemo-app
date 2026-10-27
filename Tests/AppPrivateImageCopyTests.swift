import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import PasteMemo

@Suite("isAppPrivateImageCopy")
@MainActor
struct AppPrivateImageCopyTests {
    private let home = "/Users/me"

    private func isPrivate(_ path: String, declaresImage: Bool = true) -> Bool {
        ClipboardManager.isAppPrivateImageCopy(filePaths: [path], declaresImage: declaresImage, homeDirectory: home)
    }

    @Test("Photo copied from Photos")
    func photosLibrary() {
        #expect(isPrivate("/Users/me/Pictures/Photos Library.photoslibrary/resources/renders/3/3423B1B8_1_201_a.jpeg"))
    }

    @Test("Library in another location / renamed, extension case-insensitive")
    func customLibrary() {
        #expect(isPrivate("/Volumes/Disk/Family.PhotosLibrary/originals/A/IMG_0001.heic"))
    }

    @Test("WeChat chat image in its container temp folder")
    func weChat() {
        #expect(isPrivate("/Users/me/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid/temp/RWTemp/2026-10/9e20/c14c.png"))
    }

    @Test("Other app-private and temp locations")
    func otherPrivateLocations() {
        #expect(isPrivate("/Users/me/Library/Application Support/CleanShot/media/shot.png"))
        #expect(isPrivate("/Users/me/Library/Caches/com.example/img.jpg"))
        #expect(isPrivate("/Users/me/Library/Group Containers/group.com.example/img.webp"))
        #expect(isPrivate("/private/var/folders/xy/T/img.png"))
        #expect(isPrivate("/tmp/img.png"))
    }

    @Test("User-managed folders keep the path")
    func userManaged() {
        #expect(!isPrivate("/Users/me/Pictures/截图/shot.png"))
        #expect(!isPrivate("/Users/me/Downloads/photo.jpeg"))
        #expect(!isPrivate("/Users/me/Library/Mobile Documents/com~apple~CloudDocs/photo.jpeg"))
        #expect(!isPrivate("/Users/me/Library/CloudStorage/Dropbox/photo.jpeg"))
    }

    @Test("No declared image (Finder only declares the icon) keeps the path")
    func noDeclaredImage() {
        #expect(!isPrivate("/Users/me/Library/Containers/com.tencent.xinWeChat/Data/img.png", declaresImage: false))
    }

    @Test("Multiple files keep the paths rather than dropping all but the first")
    func multipleFiles() {
        let path = "/Users/me/Pictures/Photos Library.photoslibrary/resources/renders/3/a.jpeg"
        #expect(!ClipboardManager.isAppPrivateImageCopy(filePaths: [path, path], declaresImage: true, homeDirectory: home))
    }

    @Test("A video with a poster frame on the pasteboard stays a video")
    func video() {
        #expect(!isPrivate("/Users/me/Pictures/Photos Library.photoslibrary/originals/A/IMG_0002.mov"))
    }

    @Test("GIF keeps the path so it still pastes animated")
    func gif() {
        #expect(!isPrivate("/Users/me/Library/Containers/com.tencent.xinWeChat/Data/sticker.gif"))
    }

    @Test("Copying the library package itself in Finder is a normal file copy")
    func libraryPackageItself() {
        #expect(!isPrivate("/Users/me/Pictures/Photos Library.photoslibrary"))
    }
}

@Suite("isCompleteImage")
struct CompleteImageTests {
    private func encoded(_ uti: String) throws -> Data {
        let pixels = Data([UInt8](repeating: 0x80, count: 8 * 8 * 4))
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let buffer = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(buffer, uti as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    @Test("Complete JPEG / PNG / TIFF pass", arguments: ["public.jpeg", "public.png", "public.tiff"])
    func complete(uti: String) throws {
        #expect(ClipboardManager.isCompleteImage(try encoded(uti)))
    }

    @Test("Half-written JPEG / PNG are rejected even though ImageIO reads their header",
          arguments: ["public.jpeg", "public.png"])
    func truncated(uti: String) throws {
        let data = try encoded(uti)
        let half = data.prefix(data.count / 2)
        #expect(CGImageSourceCreateWithData(half as CFData, nil) != nil)
        #expect(!ClipboardManager.isCompleteImage(half))
    }

    @Test("Empty or non-image bytes are rejected")
    func garbage() {
        #expect(!ClipboardManager.isCompleteImage(Data()))
        #expect(!ClipboardManager.isCompleteImage(Data("not an image".utf8)))
    }
}
