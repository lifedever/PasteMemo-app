import Foundation

/// Resolved bitmap preview input for zoomable image views.
enum ClipImagePreviewSource: Equatable {
    case inMemory(data: Data, cacheKey: String)
    case file(url: URL, cacheKey: String)

  /// Priority: on-disk source file → in-memory image clip → link with embedded bytes.
    static func resolve(from item: ClipItem, supplementalData: Data? = nil) -> ClipImagePreviewSource? {
        if let url = item.sourceImageFileURL {
            return .file(url: url, cacheKey: "file-\(item.itemID)")
        }

        if item.contentType == .image, let data = item.imageData, !data.isEmpty {
            return .inMemory(data: data, cacheKey: item.itemID)
        }

        if item.contentType == .link {
            if let data = item.imageData, !data.isEmpty {
                return .inMemory(data: data, cacheKey: "link-img-\(item.itemID)")
            }
            if let data = supplementalData, !data.isEmpty {
                return .inMemory(data: data, cacheKey: "data-uri-\(item.itemID)")
            }
        }

        return nil
    }

    var cacheKey: String {
        switch self {
        case .inMemory(_, let cacheKey), .file(_, let cacheKey):
            return cacheKey
        }
    }
}

extension ClipItem {
    /// Single-path file-backed image clip (Finder copy).
    var isSingleFileBackedImage: Bool {
        guard contentType == .image, content != "[Image]" else { return false }
        let paths = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return paths.count == 1
    }

    /// Link clip that should render as zoomable bitmap instead of WebView.
    var prefersZoomableLinkImagePreview: Bool {
        guard contentType == .link else { return false }
        if imageData != nil { return true }
        return DataImageURI.isBase64DataImageURI(content)
    }
}
