import Foundation

/// Detects whether text is code and identifies the language.
/// Uses a three-phase approach:
/// 1. Reject non-code formats (logs, etc.)
/// 2. Parseable languages (JSON/XML/HTML/Vue) — detect by parsing only
/// 3. highlight.js auto-detection via JavaScriptCore for all other languages
@MainActor
enum CodeDetector {

    static func isCode(_ text: String) -> Bool {
        detectLanguage(text) != nil
    }

    static func detectLanguage(_ text: String) -> CodeLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Phase 1: reject structured non-code formats
        if isLogOutput(trimmed) { return nil }

        // Phase 2: parseable formats — parsing is 100% accurate, beats regex scoring
        if isVueSFC(trimmed) { return .vue }
        if isValidJSON(trimmed) { return .json }
        if isValidXML(trimmed) { return .xml }
        if isValidHTML(trimmed) { return .html }

        // Phase 3: highlight.js auto-detection
        guard let result = HighlightEngine.shared.detectLanguage(trimmed) else {
            return nil
        }
        let detected = CodeLanguage.fromHighlightJS(result.language)

        // Phase 4: disambiguation for languages highlight.js confuses
        if let corrected = disambiguate(trimmed, detected: detected) {
            return corrected
        }
        return detected
    }

    // MARK: - Disambiguation

    /// Corrects common highlight.js misdetections where languages have overlapping syntax.
    private static func disambiguate(_ text: String, detected: CodeLanguage?) -> CodeLanguage? {
        guard let detected else { return nil }

        // C# vs TypeScript/JavaScript: highlight.js often confuses these
        if detected == .csharp {
            let hasJSImport = hasMatch(text, #"\bimport\s+.*\s+from\s+['\"]"#)
            let hasExport = hasMatch(text, #"\bexport\s+(const|default|function|class|type|interface|enum)\b"#)
            let hasArrowFn = hasMatch(text, #"=>\s*[\{\(\[]"#)
            let hasRequire = hasMatch(text, #"\brequire\s*\("#)
            let hasConsole = hasMatch(text, #"\bconsole\.\w+\("#)

            if hasJSImport || hasExport || hasArrowFn || hasRequire || hasConsole {
                // Distinguish TS from JS: type annotations, interface, generics
                let hasTypeAnnotation = hasMatch(text, #":\s*(string|number|boolean|any|void|never|unknown)\b"#)
                let hasInterface = hasMatch(text, #"\b(interface|type)\s+\w+\s*[={<]"#)
                let hasGeneric = hasMatch(text, #"\b(Record|Partial|Pick|Omit|Required|Readonly)<"#)
                return (hasTypeAnnotation || hasInterface || hasGeneric) ? .typescript : .javascript
            }
        }

        // C# vs Java: both use namespaces and classes
        if detected == .csharp {
            let hasJavaPackage = hasMatch(text, #"\bpackage\s+[a-z]+(\.[a-z]+)+"#)
            let hasSystemOut = hasMatch(text, #"\bSystem\.out\.\w+"#)
            let hasOverride = hasMatch(text, #"@Override\b"#)
            if hasJavaPackage || hasSystemOut || hasOverride { return .java }
        }

        return nil
    }

    // MARK: - Format-Based Detection (parsing only)

    private static func isVueSFC(_ text: String) -> Bool {
        let hasTemplate = hasMatch(text, #"<template[\s>]"#)
        let hasScript = hasMatch(text, #"<script\b"#)
        guard hasTemplate || hasScript else { return false }
        return hasMatch(text, #"<script\s+setup"#)
            || hasMatch(text, #"<style\s+(scoped|module)"#)
            || hasMatch(text, #"\bv-(for|if|else|else-if|show|model|bind|on|slot|html|text)\b"#)
            || hasMatch(text, #"\b(defineProps|defineEmits|defineExpose|withDefaults)\b"#)
            || hasMatch(text, #"@(click|input|change|submit|keydown|keyup)\b"#)
            || hasMatch(text, #":(key|class|style|is|ref)\b"#)
    }

    private static func isValidJSON(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[" else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isValidXML(_ text: String) -> Bool {
        guard text.hasPrefix("<?xml") || text.hasPrefix("<![CDATA[") else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        return XMLParser(data: data).parse()
    }

    private static func isValidHTML(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") else { return false }
        return hasMatch(text, #"</?(head|body|div|span|title)\b"#, caseInsensitive: true)
    }

    // MARK: - Non-Code Format Detection

    private static func isLogOutput(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmpty.count >= 2 else { return false }

        let logPatterns: [String] = [
            #"^\[?\w+\]?\s*\[?\d{4}[-/]\d{2}[-/]\d{2}"#,
            #"^\[\w+\]\s+"#,
            #"^\d{4}[-/]\d{2}[-/]\d{2}[\sT]\d{2}:\d{2}:\d{2}"#,
            #"^\w+\s+\d{2}\s+\d{2}:\d{2}:\d{2}\s+"#,
        ]

        let logLineCount = nonEmpty.filter { line in
            logPatterns.contains { hasMatch(line, $0) }
        }.count

        return Double(logLineCount) / Double(nonEmpty.count) > 0.5
    }

    // MARK: - Helpers

    private static func hasMatch(_ text: String, _ pattern: String, caseInsensitive: Bool = false) -> Bool {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, range: range) > 0
    }
}

// MARK: - Language Enum

enum CodeLanguage: String, CaseIterable {
    case swift, python, javascript, typescript, java, kotlin
    case go, rust, html, css, xml, json, yaml, sql, shell, markdown, vue
    case c, cpp, csharp, objectivec
    case ruby, php, lua, dart, scala, perl
    case dockerfile, powershell, diff, makefile
    case unknown

    /// Map highlight.js language identifier to CodeLanguage.
    static func fromHighlightJS(_ name: String) -> CodeLanguage? {
        HLJS_MAP[name]
    }

    var displayName: String {
        switch self {
        case .swift: "Swift"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .go: "Go"
        case .rust: "Rust"
        case .html: "HTML"
        case .css: "CSS"
        case .sql: "SQL"
        case .shell: "Shell/Bash"
        case .xml: "XML"
        case .json: "JSON"
        case .yaml: "YAML"
        case .markdown: "Markdown"
        case .vue: "Vue"
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .objectivec: "Obj-C"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .lua: "Lua"
        case .dart: "Dart"
        case .scala: "Scala"
        case .perl: "Perl"
        case .dockerfile: "Dockerfile"
        case .powershell: "PowerShell"
        case .diff: "Diff"
        case .makefile: "Makefile"
        case .unknown: "Auto"
        }
    }

    /// Languages available in the manual picker.
    static let pickerChoices: [CodeLanguage] = [
        .swift, .kotlin, .java, .python,
        .c, .cpp, .csharp, .objectivec,
        .javascript, .typescript, .go, .rust,
        .ruby, .php, .lua, .dart, .scala, .perl,
        .html, .xml, .css, .json, .yaml, .sql,
        .shell, .powershell, .dockerfile, .makefile,
        .markdown, .diff, .vue,
    ]

    var fileExtension: String {
        switch self {
        case .swift: "swift"
        case .python: "py"
        case .javascript: "js"
        case .typescript: "ts"
        case .java: "java"
        case .kotlin: "kt"
        case .go: "go"
        case .rust: "rs"
        case .html: "html"
        case .css: "css"
        case .sql: "sql"
        case .shell: "sh"
        case .xml: "xml"
        case .json: "json"
        case .yaml: "yml"
        case .markdown: "md"
        case .vue: "vue"
        case .c: "c"
        case .cpp: "cpp"
        case .csharp: "cs"
        case .objectivec: "m"
        case .ruby: "rb"
        case .php: "php"
        case .lua: "lua"
        case .dart: "dart"
        case .scala: "scala"
        case .perl: "pl"
        case .dockerfile: "dockerfile"
        case .powershell: "ps1"
        case .diff: "diff"
        case .makefile: "makefile"
        case .unknown: "txt"
        }
    }

    /// highlight.js language name for this CodeLanguage.
    var hljsName: String {
        switch self {
        case .shell: "bash"
        case .cpp: "cpp"
        case .csharp: "csharp"
        case .objectivec: "objectivec"
        default: rawValue
        }
    }

    // MARK: - highlight.js name → CodeLanguage mapping

    private static let HLJS_MAP: [String: CodeLanguage] = [
        "c": .c,
        "cpp": .cpp,
        "csharp": .csharp,
        "objectivec": .objectivec,
        "swift": .swift,
        "python": .python,
        "python-repl": .python,
        "javascript": .javascript,
        "typescript": .typescript,
        "java": .java,
        "kotlin": .kotlin,
        "go": .go,
        "rust": .rust,
        "html": .html,
        "xml": .xml,
        "css": .css,
        "json": .json,
        "yaml": .yaml,
        "sql": .sql,
        "bash": .shell,
        "shell": .shell,
        "markdown": .markdown,
        "ruby": .ruby,
        "php": .php,
        "php-template": .php,
        "lua": .lua,
        "dart": .dart,
        "scala": .scala,
        "perl": .perl,
        "dockerfile": .dockerfile,
        "powershell": .powershell,
        "diff": .diff,
        "makefile": .makefile,
    ]
}
