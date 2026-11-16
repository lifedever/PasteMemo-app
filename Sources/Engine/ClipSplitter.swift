import Foundation

/// Cuts one clip's text into pieces — the rules behind ⌘K「拆分」. Pure and
/// thread-agnostic: the split page runs it off the main thread when the rule is a
/// user regex (a pathological pattern can backtrack for a long time).
enum ClipSplitter {
    /// More than this and the split is refused: a stray `.` regex would otherwise
    /// flood the history with thousands of one-character clips.
    static let MAX_PIECES = 500

    enum Rule: Hashable, Sendable {
        /// Numbered items, else paragraphs, else lines, else a list separator (`、` `|`
        /// tab) that cuts a single line into short pieces.
        case auto
        case line
        case paragraph
        /// One piece per list item (`1.` `2、` `①` `一、` `-` `•` …); lines in between
        /// stay with the item above them.
        case numbered
        case delimiter(Delimiter)
        /// Cut wherever the pattern matches and drop the match. `^` / `$` match at line
        /// boundaries; a lookahead such as `(?=^\d+\.)` cuts without dropping anything.
        case regex(String)
    }

    enum Delimiter: Hashable, Sendable {
        case chineseComma
        /// `,` and `，` alike.
        case comma
        /// `;` and `；` alike.
        case semicolon
        case pipe
        case tab
        case custom(String)

        static let presets: [Delimiter] = [.chineseComma, .comma, .semicolon, .pipe, .tab]

        var titleKey: String {
            switch self {
            case .chineseComma: "split.delimiter.chineseComma"
            case .comma: "split.delimiter.comma"
            case .semicolon: "split.delimiter.semicolon"
            case .pipe: "split.delimiter.pipe"
            case .tab: "split.delimiter.tab"
            case .custom: "split.delimiter.custom"
            }
        }

        fileprivate func components(of text: String) -> [String] {
            switch self {
            case .chineseComma: text.components(separatedBy: "、")
            case .comma: text.components(separatedBy: CharacterSet(charactersIn: ",，"))
            case .semicolon: text.components(separatedBy: CharacterSet(charactersIn: ";；"))
            case .pipe: text.components(separatedBy: "|")
            case .tab: text.components(separatedBy: "\t")
            case .custom(let separator): separator.isEmpty ? [text] : text.components(separatedBy: separator)
            }
        }
    }

    /// What `.auto` settled on, shown next to「自动」.
    enum Resolved: Hashable, Sendable {
        case line, paragraph, numbered
        case delimiter(Delimiter)
    }

    struct Result: Equatable, Sendable {
        var pieces: [String]
        /// Set for `.auto` when one of the rules cut the text.
        var resolved: Resolved?
        /// At least two pieces start with a list marker, so「去掉序号」means something.
        var canStripNumbering = false
        var invalidPattern = false

        var isOverLimit: Bool { pieces.count > ClipSplitter.MAX_PIECES }
        var isSplittable: Bool { !invalidPattern && !isOverLimit && pieces.count >= 2 }
    }

    /// `isCancelled` is polled between regex matches so a superseded run can stop early.
    static func split(
        _ text: String, rule: Rule, stripNumbering: Bool,
        isCancelled: () -> Bool = { false }
    ) -> Result {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: Result
        switch rule {
        case .auto: result = auto(normalized)
        case .line: result = Result(pieces: byLine(normalized))
        case .paragraph: result = Result(pieces: byParagraph(normalized))
        case .numbered: result = Result(pieces: byNumber(normalized) ?? clean([normalized]))
        case .delimiter(let delimiter): result = Result(pieces: clean(delimiter.components(of: normalized)))
        case .regex(let pattern):
            if let pieces = byRegex(normalized, pattern: pattern, isCancelled: isCancelled) {
                result = Result(pieces: pieces)
            } else {
                result = Result(pieces: [], invalidPattern: true)
            }
        }
        result.canStripNumbering = result.pieces.filter { markerMatch(in: $0) != nil }.count >= 2
        if result.canStripNumbering, stripNumbering {
            result.pieces = clean(result.pieces.map(strippingMarker))
        }
        result.pieces = unique(result.pieces)
        return result
    }

    // MARK: - Rules

    private static func auto(_ text: String) -> Result {
        if let pieces = byNumber(text) { return Result(pieces: pieces, resolved: .numbered) }
        let paragraphs = byParagraph(text)
        if paragraphs.count >= 2 { return Result(pieces: paragraphs, resolved: .paragraph) }
        let lines = byLine(text)
        if lines.count >= 2 { return Result(pieces: lines, resolved: .line) }
        // One line: a list like "Swift、SwiftUI、AppKit". Only separators that mean "list"
        // (commas and semicolons cut ordinary sentences too — pick those by hand), and only
        // when every piece is short.
        var best: (pieces: [String], delimiter: Delimiter)?
        for delimiter in [Delimiter.chineseComma, .pipe, .tab] {
            let pieces = clean(delimiter.components(of: text))
            guard pieces.count >= 2, pieces.allSatisfy({ $0.count <= 40 }) else { continue }
            if pieces.count > (best?.pieces.count ?? 0) { best = (pieces, delimiter) }
        }
        if let best { return Result(pieces: best.pieces, resolved: .delimiter(best.delimiter)) }
        return Result(pieces: clean([text]))
    }

    private static func byLine(_ text: String) -> [String] {
        clean(text.components(separatedBy: "\n"))
    }

    private static func byParagraph(_ text: String) -> [String] {
        let pieces = text.replacingOccurrences(
            of: #"\n[ \t　]*\n"#, with: "\u{0}", options: .regularExpression
        )
        return clean(pieces.components(separatedBy: "\u{0}"))
    }

    /// nil when fewer than two lines start an item. Items are lines that carry the same
    /// kind of marker as the first one, at the same indent or shallower; anything else
    /// (wrapped lines, indented sub-bullets) belongs to the item above. Text before the
    /// first item is a piece of its own.
    private static func byNumber(_ text: String) -> [String]? {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.lazy.compactMap(markerInfo).first else { return nil }
        let startsItem: (String) -> Bool = { line in
            guard let info = markerInfo(line) else { return false }
            return info.family == first.family && info.indent <= first.indent
        }
        guard lines.filter(startsItem).count >= 2 else { return nil }

        var preamble: [String] = []
        var items: [[String]] = []
        for line in lines {
            if startsItem(line) {
                items.append([String(line.drop { $0.isWhitespace })])
            } else if items.isEmpty {
                preamble.append(line)
            } else {
                items[items.count - 1].append(line)
            }
        }
        let pieces = items.map { item in
            ([item[0]] + dedent(Array(item.dropFirst()))).joined(separator: "\n")
        }
        return clean([preamble.joined(separator: "\n")] + pieces)
    }

    /// nil = the pattern doesn't compile.
    private static func byRegex(_ text: String, pattern: String, isCancelled: () -> Bool) -> [String]? {
        guard !pattern.isEmpty else { return clean([text]) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return nil
        }
        let ns = text as NSString
        var parts: [String] = []
        var last = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            if isCancelled() || parts.count > MAX_PIECES * 4 {
                stop.pointee = true
                return
            }
            guard let range = match?.range, NSMaxRange(range) > 0 else { return }
            parts.append(ns.substring(with: NSRange(location: last, length: range.location - last)))
            last = NSMaxRange(range)
        }
        parts.append(ns.substring(from: last))
        return clean(parts)
    }

    // MARK: - List markers

    private enum MarkerFamily { case number, parenNumber, circled, chineseNumeral, bullet }

    /// `1.` `1、` `1)` `（1）` `①` `一、` `- ` `* ` `•` at the start of a line. `(?!\d)`
    /// keeps "1.5 倍" and "2026.11.16" from passing as items.
    private static let markerRegex = try! NSRegularExpression(
        pattern: #"^([ \t　]*)(?:(\d{1,3})[.．、)）](?!\d)|[（(](\d{1,3})[)）]|([①-⑳])|([一二三四五六七八九十]{1,3})、|([-*](?=[ \t])|[•·▪]))[ \t　]*"#
    )

    private static func markerMatch(in text: String) -> NSTextCheckingResult? {
        let ns = text as NSString
        let firstLineEnd = ns.range(of: "\n").location
        let length = firstLineEnd == NSNotFound ? ns.length : firstLineEnd
        return markerRegex.firstMatch(in: text, range: NSRange(location: 0, length: length))
    }

    private static func markerInfo(_ line: String) -> (family: MarkerFamily, indent: Int)? {
        guard let match = markerMatch(in: line) else { return nil }
        let family: MarkerFamily
        if match.range(at: 2).location != NSNotFound { family = .number }
        else if match.range(at: 3).location != NSNotFound { family = .parenNumber }
        else if match.range(at: 4).location != NSNotFound { family = .circled }
        else if match.range(at: 5).location != NSNotFound { family = .chineseNumeral }
        else { family = .bullet }
        let leading = (line as NSString).substring(with: match.range(at: 1))
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return (family, indent)
    }

    private static func strippingMarker(_ piece: String) -> String {
        guard let match = markerMatch(in: piece) else { return piece }
        return (piece as NSString).substring(from: NSMaxRange(match.range))
    }

    // MARK: - Helpers

    private static func clean(_ pieces: [String]) -> [String] {
        pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The same text twice would be merged into one clip anyway (dedup rule).
    private static func unique(_ pieces: [String]) -> [String] {
        var seen = Set<String>()
        return pieces.filter { seen.insert($0).inserted }
    }

    /// Strip the indentation continuation lines share, keeping their relative layout.
    private static func dedent(_ lines: [String]) -> [String] {
        let indents = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" || $0 == "\u{3000}" }.count }
        guard let common = indents.min(), common > 0 else { return lines }
        return lines.map { line in
            let leading = line.prefix { $0 == " " || $0 == "\t" || $0 == "\u{3000}" }.count
            return String(line.dropFirst(min(common, leading)))
        }
    }
}
