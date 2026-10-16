import Foundation

/// The text-toolbox rule actions (Base64, JSON, naming styles, width, 简→繁,
/// line tools, HTML tags). Pure functions; anything they can't handle comes back
/// unchanged so a rule never mangles a clip it wasn't meant for.
enum TextTools {

    // MARK: - Base64

    static func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// Accepts standard and URL-safe alphabets, missing padding and line breaks.
    /// Only returns the decoded text when it's valid UTF-8 without control
    /// characters — "hello" happens to be valid Base64 but isn't meant as such.
    static func base64Decode(_ text: String) -> String {
        var compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return text }
        compact = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = compact.count % 4
        if remainder == 1 { return text }
        if remainder > 0 { compact += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: compact),
              let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty else { return text }
        let hasControl = decoded.unicodeScalars.contains {
            $0.properties.generalCategory == .control && !["\n", "\r", "\t"].contains($0)
        }
        return hasControl ? text : decoded
    }

    // MARK: - JSON

    /// Re-indents a JSON object / array with two spaces. Works on the text, not on a
    /// parsed dictionary, so key order and number literals stay exactly as written.
    static func formatJSON(_ text: String) -> String {
        guard let trimmed = validJSONContainer(text) else { return text }
        return reflowJSON(trimmed, pretty: true)
    }

    static func minifyJSON(_ text: String) -> String {
        guard let trimmed = validJSONContainer(text) else { return text }
        return reflowJSON(trimmed, pretty: false)
    }

    private static func validJSONContainer(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first, first == "{" || first == "[",
              let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return trimmed
    }

    private static func reflowJSON(_ json: String, pretty: Bool) -> String {
        let scalars = Array(json.unicodeScalars)
        var out = String.UnicodeScalarView()
        var level = 0
        var inString = false
        var escaped = false

        func newline() {
            guard pretty else { return }
            out.append("\n")
            for _ in 0..<max(level, 0) { out.append(contentsOf: "  ".unicodeScalars) }
        }

        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                // Keep empty containers on one line: {} / [].
                var j = i + 1
                while j < scalars.count, scalars[j].properties.isWhitespace { j += 1 }
                if j < scalars.count, (c == "{" && scalars[j] == "}") || (c == "[" && scalars[j] == "]") {
                    out.append(c)
                    out.append(scalars[j])
                    i = j + 1
                    continue
                }
                out.append(c)
                level += 1
                newline()
            case "}", "]":
                level -= 1
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(c)
                if pretty { out.append(" ") }
            default:
                if !c.properties.isWhitespace { out.append(c) }
            }
            i += 1
        }
        return String(out)
    }

    // MARK: - Naming styles

    /// `user_name` / `User Name` / `user-name` → `userName`; one identifier per line.
    static func camelCase(_ text: String) -> String {
        mapLines(text) { words in
            words.enumerated().map { index, word in
                index == 0 ? word.lowercased() : word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }.joined()
        }
    }

    /// `userName` / `User Name` / `XMLHttpRequest` → `user_name` / `xml_http_request`.
    static func snakeCase(_ text: String) -> String {
        mapLines(text) { words in words.map { $0.lowercased() }.joined(separator: "_") }
    }

    /// Applies `transform` to the words of each line, keeping the line's indentation.
    /// Lines without any letters or digits stay as they are.
    private static func mapLines(_ text: String, _ transform: ([String]) -> String) -> String {
        text.components(separatedBy: "\n").map { line in
            let words = identifierWords(line)
            guard !words.isEmpty else { return line }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            return indent + transform(words)
        }.joined(separator: "\n")
    }

    /// Splits on anything that isn't a letter or digit, and on case changes:
    /// `userName` → user|Name, `XMLHttp` → XML|Http. Digits stay with their word.
    static func identifierWords(_ line: String) -> [String] {
        let chars = Array(line)
        var words: [String] = []
        var current = ""
        for (index, ch) in chars.enumerated() {
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if let previous = current.last {
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                let lowerToUpper = (previous.isLowercase || previous.isNumber) && ch.isUppercase
                let acronymEnd = previous.isUppercase && ch.isUppercase && (next?.isLowercase ?? false)
                if lowerToUpper || acronymEnd {
                    words.append(current)
                    current = ""
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    // MARK: - Width

    /// Full-width ASCII (ＡＢＣ１２３，！) and the ideographic space → half-width.
    /// CJK punctuation (。、「」) has no ASCII counterpart and is left alone — the
    /// system transform would turn 。 into the half-width katakana ｡.
    static func halfWidth(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E: out.append(Unicode.Scalar(scalar.value - 0xFEE0)!)
            case 0x3000: out.append(" ")
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Printable ASCII and the space → full-width.
    static func fullWidth(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x21...0x7E: out.append(Unicode.Scalar(scalar.value + 0xFEE0)!)
            case 0x20: out.append("\u{3000}")
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    // MARK: - Chinese script

    /// Character-level: 后台 → 後台, 头发 → 頭髮, but 软件 stays 軟件 (no 軟體 —
    /// that's a vocabulary change, not a script one).
    static func simplifiedToTraditional(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    // MARK: - Lines

    /// Drops repeated lines, keeping the first; blank lines are left in place.
    static func removeDuplicateLines(_ text: String) -> String {
        var seen = Set<String>()
        return text.components(separatedBy: "\n").filter { line in
            let key = line.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return true }
            return seen.insert(key).inserted
        }.joined(separator: "\n")
    }

    /// Natural order (file2 before file10); blank lines are dropped.
    static func sortLines(_ text: String, ascending: Bool) -> String {
        let lines = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let sorted = lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (ascending ? sorted : sorted.reversed()).joined(separator: "\n")
    }

    /// Trims each line and joins the non-empty ones with `separator`.
    static func joinLines(_ text: String, separator: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    // MARK: - HTML

    /// Strips tags from HTML source, keeping line breaks where blocks ended and
    /// decoding the common entities. Regex only — no WebKit, safe off the main thread.
    /// Text without anything tag-shaped comes back unchanged.
    static func removeHTMLTags(_ text: String) -> String {
        guard text.range(of: "</?[A-Za-z][^<>]*>", options: .regularExpression) != nil else { return text }
        var s = text
        s = replace(s, "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: "")
        s = replace(s, "(?s)<!--.*?-->", with: "")
        s = replace(s, "(?i)<br\\s*/?>", with: "\n")
        s = replace(s, "(?i)</(p|div|li|tr|h[1-6]|blockquote|pre|table|ul|ol)\\s*>", with: "\n")
        s = replace(s, "</?[A-Za-z][^<>]*>", with: "")
        s = replace(s, "<![^>]*>", with: "")
        s = decodeEntities(s)
        s = replace(s, "[ \\t]+\\n", with: "\n")
        s = replace(s, "\\n{3,}", with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var s = text
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            s = s.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        s = replaceNumericEntities(s, pattern: "&#x([0-9A-Fa-f]{1,6});", radix: 16)
        s = replaceNumericEntities(s, pattern: "&#([0-9]{1,7});", radix: 10)
        // Last, so "&amp;lt;" becomes "&lt;" and not "<".
        return s.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    private static func replaceNumericEntities(_ text: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let digits = ns.substring(with: match.range(at: 1))
            if let code = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            } else {
                result += ns.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}
