import AppKit
import JavaScriptCore

// MARK: - Highlight Token

struct HighlightToken: Sendable {
    let text: String
    let scope: String?
}

// MARK: - Engine

/// Wraps highlight.js via JavaScriptCore for language detection and syntax highlighting.
/// Uses a cached JSContext on main thread for performance.
@MainActor
final class HighlightEngine {
    static let shared = HighlightEngine()

    private let jsSource: String
    private var cachedContext: JSContext?

    /// LRU cache for highlight results: hash-based key → tokens
    private var highlightCache: [Int: [HighlightToken]] = [:]
    private var cacheKeys: [Int] = []
    private let maxCacheSize = 50

    /// Languages to consider during auto-detection.
    private let candidateLanguages = [
        "c", "cpp", "csharp", "python", "swift", "java", "kotlin",
        "go", "rust", "javascript", "typescript", "sql", "bash", "shell",
        "css", "json", "xml", "yaml", "markdown", "ruby", "php",
        "objectivec", "dart", "scala", "lua", "dockerfile", "powershell",
        "diff", "makefile", "perl",
    ]

    private init() {
        guard let url = Bundle.module.url(
            forResource: "highlight.min",
            withExtension: "js",
            subdirectory: "Resources"
        ) else {
            fatalError("highlight.min.js not found in bundle")
        }
        jsSource = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Detection

    struct DetectionResult {
        let language: String
        let relevance: Int
    }

    func detectLanguage(_ code: String) -> DetectionResult? {
        let ctx = getContext()
        let langsArray = candidateLanguages.map { "'\($0)'" }.joined(separator: ",")
        let escaped = escapeForJS(code)
        let script = "var r = hljs.highlightAuto('\(escaped)', [\(langsArray)]); " +
            "JSON.stringify({language: r.language, relevance: r.relevance})"

        guard let result = ctx.evaluateScript(script),
              !result.isUndefined,
              let json = result.toString(),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let language = dict["language"] as? String,
              let relevance = dict["relevance"] as? Int
        else { return nil }

        guard relevance >= 5 else { return nil }
        return DetectionResult(language: language, relevance: relevance)
    }

    // MARK: - Highlighting

    func highlight(_ code: String, language: String) -> [HighlightToken] {
        var hasher = Hasher()
        hasher.combine(language)
        hasher.combine(code)
        let cacheKey = hasher.finalize()
        if let cached = highlightCache[cacheKey] {
            if let idx = cacheKeys.firstIndex(of: cacheKey) {
                cacheKeys.remove(at: idx)
                cacheKeys.append(cacheKey)
            }
            return cached
        }

        let ctx = getContext()
        let escaped = escapeForJS(code)
        let script = "(function(){return hljs.highlight('\(escaped)',{language:'\(language)',ignoreIllegals:true}).value})()"

        guard let result = ctx.evaluateScript(script),
              !result.isUndefined,
              let html = result.toString()
        else { return [HighlightToken(text: code, scope: nil)] }

        let tokens = parseTokens(from: html)
        putCache(cacheKey, tokens)
        return tokens
    }

    // MARK: - Cache

    private func putCache(_ key: Int, _ tokens: [HighlightToken]) {
        if highlightCache[key] != nil {
            cacheKeys.removeAll { $0 == key }
        } else if cacheKeys.count >= maxCacheSize, let oldest = cacheKeys.first {
            cacheKeys.removeFirst()
            highlightCache.removeValue(forKey: oldest)
        }
        highlightCache[key] = tokens
        cacheKeys.append(key)
    }

    // MARK: - HTML → Tokens

    private func parseTokens(from html: String) -> [HighlightToken] {
        var tokens: [HighlightToken] = []
        var scopeStack: [String?] = [nil]
        let chars = Array(html.utf16)
        let count = chars.count
        var i = 0

        while i < count {
            if chars[i] == 0x3C { // '<'
                if let tagEnd = findClosingAngle(chars, from: i, count: count) {
                    let tagStr = String(utf16CodeUnits: Array(chars[i...tagEnd]), count: tagEnd - i + 1)

                    if tagStr.hasPrefix("<span") {
                        scopeStack.append(extractScope(from: tagStr))
                    } else if tagStr == "</span>" {
                        if scopeStack.count > 1 { scopeStack.removeLast() }
                    }
                    i = tagEnd + 1
                    continue
                }
            }

            var textEnd = i
            while textEnd < count && chars[textEnd] != 0x3C { textEnd += 1 }

            if i < textEnd {
                let raw = String(utf16CodeUnits: Array(chars[i..<textEnd]), count: textEnd - i)
                let decoded = decodeHTMLEntities(raw)
                tokens.append(HighlightToken(text: decoded, scope: scopeStack.last ?? nil))
            }
            i = textEnd
        }

        return tokens
    }

    private func findClosingAngle(_ chars: [UInt16], from start: Int, count: Int) -> Int? {
        var idx = start
        while idx < count {
            if chars[idx] == 0x3E { return idx } // '>'
            idx += 1
        }
        return nil
    }

    private func extractScope(from tag: String) -> String? {
        guard let classRange = tag.range(of: "class=\"hljs-") else { return nil }
        let scopeStart = classRange.upperBound
        guard let quoteEnd = tag[scopeStart...].firstIndex(of: "\"") else { return nil }
        return String(tag[scopeStart..<quoteEnd])
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    // MARK: - JSContext

    private func getContext() -> JSContext {
        if let ctx = cachedContext { return ctx }
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, _ in }
        ctx.evaluateScript(jsSource)
        cachedContext = ctx
        return ctx
    }

    // MARK: - Escaping

    private func escapeForJS(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\u{2028}", with: "\\n")
            .replacingOccurrences(of: "\u{2029}", with: "\\n")
    }
}
