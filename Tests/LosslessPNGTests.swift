import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PasteMemo

@Suite("LosslessPNG")
struct LosslessPNGTests {
    /// A 16×16 gradient over every channel; `translucent` varies alpha too.
    private func image(
        space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!, bitsPerComponent: Int = 8,
        alpha: CGImageAlphaInfo = .premultipliedLast, translucent: Bool = false
    ) throws -> CGImage {
        let size = 16
        let context = try #require(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
            space: space, bitmapInfo: alpha.rawValue
        ))
        for y in 0..<size {
            for x in 0..<size {
                let components: [CGFloat] = space.numberOfComponents == 4
                    ? [CGFloat(x) / 15, CGFloat(y) / 15, 0.3, 0.1, 1]
                    : [CGFloat(x) / 15, CGFloat(y) / 15, 0.5, translucent ? CGFloat(x + y) / 30 + 0.2 : 1]
                context.setFillColor(CGColor(colorSpace: space, components: components)!)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try #require(context.makeImage())
    }

    private func tiff(_ images: [CGImage], properties: [CFString: Any]? = nil) throws -> Data {
        let buffer = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(buffer, UTType.tiff.identifier as CFString, images.count, nil))
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary?) }
        #expect(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test("8-bit RGBA TIFF becomes a PNG with identical pixels")
    func rgba8() throws {
        let original = try image()
        let png = try #require(LosslessPNG.convert(try tiff([original])))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(LosslessPNG.samePixels(try decode(tiff([original])), try decode(png)))
    }

    @Test("Translucent pixels: converted only when every pixel survives")
    func translucent() throws {
        // Premultiplied 8-bit alpha may not survive PNG's straight alpha; then it must stay TIFF.
        let data = try tiff([image(translucent: true)])
        if let png = LosslessPNG.convert(data) {
            #expect(LosslessPNG.samePixels(try decode(data), try decode(png)))
        }
    }

    @Test("Display P3 keeps its profile")
    func displayP3() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let png = try #require(LosslessPNG.convert(try tiff([image(space: p3)])))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect((properties?[kCGImagePropertyProfileName] as? String)?.contains("P3") == true)
    }

    @Test("16-bit TIFF round-trips")
    func rgba16() throws {
        #expect(LosslessPNG.convert(try tiff([image(bitsPerComponent: 16)])) != nil)
    }

    @Test("Multi-page TIFF stays TIFF — PNG holds one image")
    func multiPage() throws {
        #expect(LosslessPNG.convert(try tiff([image(), image()])) == nil)
    }

    @Test("CMYK TIFF stays TIFF — PNG has no CMYK")
    func cmyk() throws {
        let cmyk = try #require(CGColorSpace(name: CGColorSpace.genericCMYK))
        #expect(LosslessPNG.convert(try tiff([image(space: cmyk, alpha: .none)])) == nil)
    }

    @Test("Floating-point TIFF stays TIFF")
    func float() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 32, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
        ))
        context.setFillColor(CGColor(colorSpace: space, components: [1.5, 0.2, 0.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(LosslessPNG.convert(try tiff([try #require(context.makeImage())])) == nil)
    }

    @Test("Garbage stays untouched")
    func garbage() {
        #expect(LosslessPNG.convert(Data("not an image".utf8)) == nil)
    }

    @Test("Banded compare: a difference past the first band and a ragged last band are both caught")
    func bands() throws {
        let width = 40, height = 300
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func make(_ marked: Bool) throws -> CGImage {
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if marked {
                // y = 3 from the bottom is image row 296 — inside the 44-row last band.
                context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: 10, y: 3, width: 1, height: 1))
            }
            return try #require(context.makeImage())
        }
        #expect(LosslessPNG.samePixels(try make(false), try make(false)))
        #expect(!LosslessPNG.samePixels(try make(false), try make(true)))
        let png = try #require(LosslessPNG.convert(try tiff([make(true)])))
        #expect(LosslessPNG.samePixels(try make(true), try decode(png)))
    }

    @Test("A single changed pixel is caught")
    func detectsDifference() throws {
        let original = try image()
        let context = try #require(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(original, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 7, y: 7, width: 1, height: 1))
        #expect(!LosslessPNG.samePixels(original, try #require(context.makeImage())))
        #expect(LosslessPNG.samePixels(original, original))
    }
}
