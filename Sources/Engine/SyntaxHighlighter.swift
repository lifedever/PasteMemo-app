import AppKit

actor SyntaxHighlightWorker {
    static let shared = SyntaxHighlightWorker()

    func highlight(code: String, language: String) async -> [HighlightToken] {
        await MainActor.run {
            HighlightEngine.shared.highlight(code, language: language)
        }
    }
}

// MARK: - Theme

struct SyntaxTheme {
    let keyword: NSColor
    let string: NSColor
    let comment: NSColor
    let number: NSColor
    let type: NSColor
    let function: NSColor
    let attribute: NSColor
    let tag: NSColor
    let property: NSColor
    let plain: NSColor
    let builtIn: NSColor
    let meta: NSColor
    let params: NSColor
    let literal: NSColor
    let deletion: NSColor
    let addition: NSColor

    static var current: SyntaxTheme {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .dark : .light
    }

    static let dark = SyntaxTheme(
        keyword: NSColor(red: 0.78, green: 0.47, blue: 0.86, alpha: 1),
        string: NSColor(red: 0.60, green: 0.76, blue: 0.38, alpha: 1),
        comment: NSColor(red: 0.38, green: 0.43, blue: 0.47, alpha: 1),
        number: NSColor(red: 0.82, green: 0.58, blue: 0.35, alpha: 1),
        type: NSColor(red: 0.90, green: 0.78, blue: 0.45, alpha: 1),
        function: NSColor(red: 0.38, green: 0.71, blue: 0.93, alpha: 1),
        attribute: NSColor(red: 0.78, green: 0.47, blue: 0.86, alpha: 1),
        tag: NSColor(red: 0.88, green: 0.36, blue: 0.36, alpha: 1),
        property: NSColor(red: 0.88, green: 0.36, blue: 0.36, alpha: 1),
        plain: NSColor(red: 0.67, green: 0.70, blue: 0.75, alpha: 1),
        builtIn: NSColor(red: 0.38, green: 0.71, blue: 0.93, alpha: 1),
        meta: NSColor(red: 0.38, green: 0.71, blue: 0.93, alpha: 1),
        params: NSColor(red: 0.67, green: 0.70, blue: 0.75, alpha: 1),
        literal: NSColor(red: 0.82, green: 0.58, blue: 0.35, alpha: 1),
        deletion: NSColor(red: 0.88, green: 0.36, blue: 0.36, alpha: 1),
        addition: NSColor(red: 0.60, green: 0.76, blue: 0.38, alpha: 1)
    )

    static let light = SyntaxTheme(
        keyword: NSColor(red: 0.66, green: 0.13, blue: 0.78, alpha: 1),
        string: NSColor(red: 0.31, green: 0.60, blue: 0.02, alpha: 1),
        comment: NSColor(red: 0.63, green: 0.65, blue: 0.66, alpha: 1),
        number: NSColor(red: 0.72, green: 0.42, blue: 0.00, alpha: 1),
        type: NSColor(red: 0.72, green: 0.42, blue: 0.00, alpha: 1),
        function: NSColor(red: 0.25, green: 0.42, blue: 0.77, alpha: 1),
        attribute: NSColor(red: 0.66, green: 0.13, blue: 0.78, alpha: 1),
        tag: NSColor(red: 0.89, green: 0.11, blue: 0.14, alpha: 1),
        property: NSColor(red: 0.89, green: 0.11, blue: 0.14, alpha: 1),
        plain: NSColor(red: 0.22, green: 0.23, blue: 0.26, alpha: 1),
        builtIn: NSColor(red: 0.25, green: 0.42, blue: 0.77, alpha: 1),
        meta: NSColor(red: 0.25, green: 0.42, blue: 0.77, alpha: 1),
        params: NSColor(red: 0.22, green: 0.23, blue: 0.26, alpha: 1),
        literal: NSColor(red: 0.72, green: 0.42, blue: 0.00, alpha: 1),
        deletion: NSColor(red: 0.89, green: 0.11, blue: 0.14, alpha: 1),
        addition: NSColor(red: 0.31, green: 0.60, blue: 0.02, alpha: 1)
    )

    /// Map highlight.js CSS scope to theme color.
    func color(forScope scope: String) -> NSColor {
        SCOPE_MAP[scope] ?? plain
    }

    private var SCOPE_MAP: [String: NSColor] {
        [
            "keyword": keyword,
            "built_in": builtIn,
            "type": type,
            "class": type,
            "title": function,
            "title.class_": type,
            "title.class.inherited__": type,
            "title.function_": function,
            "title.function.invoke__": function,
            "function": function,
            "string": string,
            "comment": comment,
            "doctag": comment,
            "number": number,
            "literal": literal,
            "attr": property,
            "attribute": attribute,
            "variable": plain,
            "variable.language_": keyword,
            "variable.constant_": literal,
            "template-variable": string,
            "regexp": string,
            "tag": tag,
            "name": tag,
            "selector-tag": tag,
            "selector-id": property,
            "selector-class": property,
            "property": property,
            "params": params,
            "meta": meta,
            "meta keyword": keyword,
            "meta string": string,
            "symbol": literal,
            "bullet": literal,
            "link": string,
            "subst": plain,
            "section": function,
            "emphasis": plain,
            "strong": plain,
            "formula": plain,
            "quote": comment,
            "addition": addition,
            "deletion": deletion,
        ]
    }
}

// MARK: - Highlighter

private let MAX_HIGHLIGHT_LENGTH = 50_000

@MainActor
enum SyntaxHighlighter {

    private static var attrStringCache: [Int: NSAttributedString] = [:]
    private static var cacheOrder: [Int] = []
    private static let MAX_CACHE_SIZE = 30

    nonisolated private static func cacheKey(for code: String, language: CodeLanguage, isDark: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(code)
        hasher.combine(language)
        hasher.combine(isDark)
        return hasher.finalize()
    }

    static func cachedHighlight(
        _ code: String,
        language: CodeLanguage,
        isDark: Bool
    ) -> NSAttributedString? {
        attrStringCache[cacheKey(for: code, language: language, isDark: isDark)]
    }

    nonisolated static func highlightOffMain(
        _ code: String,
        language: CodeLanguage,
        isDark: Bool
    ) -> NSAttributedString {
        let theme = isDark ? SyntaxTheme.dark : SyntaxTheme.light
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.plain,
        ]

        let codeToHighlight = code.count > MAX_HIGHLIGHT_LENGTH
            ? String(code.prefix(MAX_HIGHLIGHT_LENGTH))
            : code

        let result = NSMutableAttributedString(string: codeToHighlight, attributes: baseAttrs)
        if code.count > MAX_HIGHLIGHT_LENGTH {
            let remaining = String(code.dropFirst(MAX_HIGHLIGHT_LENGTH))
            result.append(NSAttributedString(string: remaining, attributes: baseAttrs))
        }
        return result
    }

    static func highlight(_ code: String, language: CodeLanguage? = nil) -> NSAttributedString {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let lang = language ?? CodeDetector.detectLanguage(code) ?? .unknown
        let cacheKey = cacheKey(for: code, language: lang, isDark: isDark)

        if let cached = attrStringCache[cacheKey] { return cached }

        let theme = isDark ? SyntaxTheme.dark : SyntaxTheme.light
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.plain,
        ]

        let codeToHighlight = code.count > MAX_HIGHLIGHT_LENGTH
            ? String(code.prefix(MAX_HIGHLIGHT_LENGTH))
            : code
        let tokens = HighlightEngine.shared.highlight(codeToHighlight, language: lang.hljsName)

        let result = NSMutableAttributedString()
        for token in tokens {
            let color = token.scope.map { theme.color(forScope: $0) } ?? theme.plain
            var attrs = baseAttrs
            attrs[.foregroundColor] = color
            result.append(NSAttributedString(string: token.text, attributes: attrs))
        }

        // Append remaining unhighlighted text for very long code
        if code.count > MAX_HIGHLIGHT_LENGTH {
            let remaining = String(code.dropFirst(MAX_HIGHLIGHT_LENGTH))
            result.append(NSAttributedString(string: remaining, attributes: baseAttrs))
        }

        putCache(cacheKey, result)
        return result
    }

    static func highlightAsync(
        _ code: String,
        language: CodeLanguage? = nil,
        isDark: Bool
    ) async -> NSAttributedString {
        let lang = language ?? CodeDetector.detectLanguage(code) ?? .unknown
        let cacheKey = cacheKey(for: code, language: lang, isDark: isDark)

        if let cached = cachedHighlight(code, language: lang, isDark: isDark) {
            return cached
        }

        let theme = isDark ? SyntaxTheme.dark : SyntaxTheme.light
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: theme.plain,
        ]

        let codeToHighlight = code.count > MAX_HIGHLIGHT_LENGTH
            ? String(code.prefix(MAX_HIGHLIGHT_LENGTH))
            : code
        let tokens = await SyntaxHighlightWorker.shared.highlight(code: codeToHighlight, language: lang.hljsName)

        let result = NSMutableAttributedString()
        for token in tokens {
            let color = token.scope.map { theme.color(forScope: $0) } ?? theme.plain
            var attrs = baseAttrs
            attrs[.foregroundColor] = color
            result.append(NSAttributedString(string: token.text, attributes: attrs))
        }

        if code.count > MAX_HIGHLIGHT_LENGTH {
            let remaining = String(code.dropFirst(MAX_HIGHLIGHT_LENGTH))
            result.append(NSAttributedString(string: remaining, attributes: baseAttrs))
        }

        let final = NSAttributedString(attributedString: result)
        putCache(cacheKey, final)
        return final
    }

    private static func putCache(_ key: Int, _ value: NSAttributedString) {
        if attrStringCache[key] != nil {
            cacheOrder.removeAll { $0 == key }
        } else if cacheOrder.count >= MAX_CACHE_SIZE, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            attrStringCache.removeValue(forKey: oldest)
        }
        attrStringCache[key] = value
        cacheOrder.append(key)
    }

}
