import Foundation

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
