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

    /// 无 scheme、无路径的「域名」里，末段是常见文件扩展名 → 按文件名处理，不是链接。
    ///
    /// `.md` `.sh` `.py` `.app` `.so` 这些全是真实 TLD，所以 `readme.md`、`build.sh`
    /// 既过得了域名正则，也会被 `NSDataDetector` 认成链接。带路径的（`example.com/x`）
    /// 不在此列——那个形状不会是文件名。
    ///
    /// Foundational: 裸域名判定的单一归属，`ClipboardManager.isURL`（整条内容）和
    /// `TextEntityExtractor`（内容片段）共用，别再各写一份名单。
    static func looksLikeFilename(_ text: String) -> Bool {
        guard !text.contains("/"), let lastDot = text.lastIndex(of: ".") else { return false }
        let suffix = text[text.index(after: lastDot)...].lowercased()
        return nonDomainSuffixes.contains(suffix)
    }

    private static let nonDomainSuffixes: Set<String> = [
        // configs / text
        "conf", "config", "ini", "env", "lock", "plist", "toml",
        "log", "txt", "md", "markdown", "rtf", "csv", "tsv",
        // data / markup
        "json", "xml", "yml", "yaml", "html", "htm", "xhtml", "sql",
        // code
        "swift", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs",
        "c", "cc", "cpp", "cxx", "h", "hpp", "hxx", "m", "mm",
        "java", "kt", "kts", "scala", "groovy", "dart", "lua",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        "php", "pl", "r", "jl", "clj", "erl", "ex", "exs",
        // binaries / archives
        "exe", "dll", "so", "dylib", "a", "o",
        "zip", "tar", "gz", "bz2", "xz", "rar", "7z",
        "iso", "dmg", "pkg", "deb", "rpm", "app",
        // documents
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
        "pages", "numbers", "keynote",
        // media
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg", "ico", "heic", "heif",
        "mp3", "wav", "flac", "ogg", "m4a", "aac",
        "mp4", "mov", "avi", "mkv", "webm", "m4v"
    ]
}
