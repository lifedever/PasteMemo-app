import Foundation
import ImageIO
import CoreGraphics

enum DataImageURI {
    static let maxDecodedImageBytes = 20 * 1024 * 1024

    static func isDataImageURI(_ text: String) -> Bool {
        guard let start = firstNonWhitespaceIndex(in: text) else { return false }
        return text[start...].hasPrefix("data:image/")
    }

    static func isBase64DataImageURI(_ text: String) -> Bool {
        guard let header = dataImageHeader(in: text) else { return false }
        return header.localizedCaseInsensitiveContains(";base64")
    }

    static func decodedImageData(from text: String, maxDecodedBytes: Int = maxDecodedImageBytes) -> Data? {
        guard let payload = dataImagePayload(in: text),
              let commaIndex = payload.firstIndex(of: ",") else { return nil }
        let header = payload[..<commaIndex]
        guard header.localizedCaseInsensitiveContains(";base64") else { return nil }

        let base64Slice = payload[payload.index(after: commaIndex)...]
        let estimatedBytes = (base64Slice.utf8.count * 3) / 4
        guard estimatedBytes <= maxDecodedBytes else { return nil }

        return Data(base64Encoded: String(base64Slice), options: .ignoreUnknownCharacters)
    }

    /// MIME subtype from the URI header (e.g. "png", "jpeg", "svg+xml") — no decode.
    static func mimeSubtype(in text: String) -> String? {
        guard let payload = dataImagePayload(in: text) else { return nil }
        let afterPrefix = payload.dropFirst("data:image/".count)
        let endIdx = afterPrefix.firstIndex { $0 == ";" || $0 == "," } ?? afterPrefix.endIndex
        let subtype = afterPrefix[..<endIdx].lowercased()
        return subtype.isEmpty ? nil : subtype
    }

    /// Short uppercase format label suitable for the badge overlay (e.g. "PNG").
    static func formatLabel(in text: String) -> String? {
        guard let subtype = mimeSubtype(in: text) else { return nil }
        switch subtype {
        case "png": return "PNG"
        case "jpeg", "jpg": return "JPG"
        case "gif": return "GIF"
        case "webp": return "WEBP"
        case "heic", "heif": return "HEIC"
        case "bmp": return "BMP"
        case "tiff": return "TIFF"
        case "svg+xml", "svg": return "SVG"
        case "x-icon", "vnd.microsoft.icon": return "ICO"
        default: return subtype.uppercased()
        }
    }

    /// Estimated size of the decoded payload, computed from the base64 length — no decode.
    static func estimatedDecodedSize(in text: String) -> Int? {
        guard let payload = dataImagePayload(in: text),
              let commaIndex = payload.firstIndex(of: ",") else { return nil }
        let header = payload[..<commaIndex]
        guard header.localizedCaseInsensitiveContains(";base64") else { return nil }
        let base64Slice = payload[payload.index(after: commaIndex)...]
        return (base64Slice.utf8.count * 3) / 4
    }

    /// Pixel dimensions read via `CGImageSource` properties — no full bitmap decode.
    static func dimensions(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }

    private static func dataImageHeader(in text: String) -> String.SubSequence? {
        guard let payload = dataImagePayload(in: text),
              let commaIndex = payload.firstIndex(of: ",") else { return nil }
        return payload[..<commaIndex]
    }

    private static func dataImagePayload(in text: String) -> String.SubSequence? {
        guard let start = firstNonWhitespaceIndex(in: text) else { return nil }
        let payload = text[start...]
        guard payload.hasPrefix("data:image/") else { return nil }
        return payload
    }

    private static func firstNonWhitespaceIndex(in text: String) -> String.Index? {
        text.firstIndex { !$0.isWhitespace }
    }
}
