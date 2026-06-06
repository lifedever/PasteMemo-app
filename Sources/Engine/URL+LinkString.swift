import Foundation

extension URL {
    /// Builds a URL from a possibly-schemeless link string.
    ///
    /// Clipboard link-detection (`ClipboardManager.isURL`) accepts bare domains
    /// like `jp.evoxt.lifedever.com`. Plain `URL(string:)` turns those into a
    /// *schemeless* URL whose `host` is nil — it can't be launched by
    /// `NSWorkspace.open` ("找不到程序"), loaded by WebView, or resolved for
    /// metadata fetch. This normaliser leaves content that already carries a
    /// scheme (https / mailto / data / …) untouched and defaults bare domains to
    /// https.
    ///
    /// Foundational: the single home for link scheme-resolution. Used by
    /// `ClipItem.resolvedURL` (open / preview) and `LinkMetadataFetcher`
    /// (title / favicon). Don't re-implement the `https://` fallback elsewhere.
    static func fromLinkString(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://\(trimmed)")
    }
}
