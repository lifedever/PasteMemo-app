import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import PasteMemo

@Suite("sniffImageExtension")
struct SniffImageExtensionTests {
    // The most compact way to produce ImageIO-recognisable bytes for each
    // format is to ask ImageIO to write them. We build a 1x1 image and
    // ask CGImageDestination to serialise it as the format under test —
    // that way the bytes are guaranteed to be what ImageIO produces for
    // the corresponding UTI, mirroring what real source apps put on the
    // pasteboard.
    private func tinyImage(uti: String) throws -> Data {
        let width = 1, height = 1
        let bytesPerRow = 4
        var pixel: [UInt8] = [0xFF, 0x00, 0x00, 0xFF]
        guard let provider = CGDataProvider(data: Data(pixel) as CFData),
              let cg = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw TestError.cgImageInitFailed
        }
        let buf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buf, uti as CFString, 1, nil) else {
            throw TestError.destinationInitFailed
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw TestError.encodeFailed
        }
        _ = pixel
        return buf as Data
    }

    enum TestError: Error { case cgImageInitFailed, destinationInitFailed, encodeFailed }

    @Test("PNG bytes → png")
    func detectsPNG() throws {
        let data = try tinyImage(uti: "public.png")
        #expect(ClipboardManager.sniffImageExtension(from: data) == "png")
    }

    @Test("JPEG bytes → jpg (normalised from 'jpeg')")
    func detectsJPEG() throws {
        let data = try tinyImage(uti: "public.jpeg")
        // UTType reports "jpeg" but we normalise to "jpg" to match Finder
        // / screenshots / pre-existing PasteMemo filenames.
        #expect(ClipboardManager.sniffImageExtension(from: data) == "jpg")
    }

    @Test("TIFF bytes → tiff (issue #48 — Telegram TIFF saved as .png)")
    func detectsTIFF() throws {
        let data = try tinyImage(uti: "public.tiff")
        #expect(ClipboardManager.sniffImageExtension(from: data) == "tiff")
    }

    @Test("GIF bytes → gif")
    func detectsGIF() throws {
        let data = try tinyImage(uti: "com.compuserve.gif")
        #expect(ClipboardManager.sniffImageExtension(from: data) == "gif")
    }

    @Test("Truncated TIFF header (big-endian) still classified via magic-byte fallback")
    func tiffHeaderFallbackBE() {
        // Just the 8-byte TIFF big-endian magic + dummy IFD offset — too
        // short for ImageIO to recognise, but the magic-byte layer should
        // still call it tiff (not the silent .png default).
        let data = Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08])
        #expect(ClipboardManager.sniffImageExtension(from: data) == "tiff")
    }

    @Test("Truncated TIFF header (little-endian) still classified via magic-byte fallback")
    func tiffHeaderFallbackLE() {
        let data = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        #expect(ClipboardManager.sniffImageExtension(from: data) == "tiff")
    }

    @Test("Garbage bytes fall back to png (last-resort default)")
    func garbageFallsBack() {
        let data = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
        #expect(ClipboardManager.sniffImageExtension(from: data) == "png")
    }
}
