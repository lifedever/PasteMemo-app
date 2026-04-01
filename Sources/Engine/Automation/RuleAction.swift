import Foundation

enum RuleAction: Codable, Equatable, Hashable, Sendable {
    case lowercased
    case uppercased
    case trimWhitespace
    case removeBlankLines
    case urlEncode
    case urlDecode
    case removeQueryParams(patterns: [String])
    case regexReplace(pattern: String, replacement: String)
    case addPrefix(text: String)
    case addSuffix(text: String)
    case stripRichText
    case assignGroup(name: String)
    case markSensitive
    case pin
    case skipCapture

    @MainActor var displayLabel: String {
        switch self {
        case .lowercased: L10n.tr("automation.action.lowercased")
        case .uppercased: L10n.tr("automation.action.uppercased")
        case .trimWhitespace: L10n.tr("automation.action.trimWhitespace")
        case .removeBlankLines: L10n.tr("automation.action.removeBlankLines")
        case .urlEncode: L10n.tr("automation.action.urlEncode")
        case .urlDecode: L10n.tr("automation.action.urlDecode")
        case .removeQueryParams: L10n.tr("automation.action.removeQueryParams")
        case .regexReplace: L10n.tr("automation.action.regexReplace")
        case .addPrefix: L10n.tr("automation.action.addPrefix")
        case .addSuffix: L10n.tr("automation.action.addSuffix")
        case .stripRichText: L10n.tr("automation.action.stripRichText")
        case .assignGroup(let name): L10n.tr("automation.action.assignGroup") + ": " + name
        case .markSensitive: L10n.tr("automation.action.markSensitive")
        case .pin: L10n.tr("automation.action.pin")
        case .skipCapture: L10n.tr("automation.action.skipCapture")
        }
    }

    func execute(on content: String) -> String {
        switch self {
        case .lowercased:
            return content.lowercased()
        case .uppercased:
            return content.uppercased()
        case .trimWhitespace:
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        case .removeBlankLines:
            return removeExcessiveBlankLines(content)
        case .urlEncode:
            // RFC 3986 unreserved characters: ALPHA / DIGIT / "-" / "." / "_" / "~"
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return content.addingPercentEncoding(withAllowedCharacters: allowed) ?? content
        case .urlDecode:
            return content.removingPercentEncoding ?? content
        case .removeQueryParams(let patterns):
            return removeMatchingQueryParams(from: content, patterns: patterns)
        case .regexReplace(let pattern, let replacement):
            return applyRegexReplace(content, pattern: pattern, replacement: replacement)
        case .addPrefix(let text):
            return text + content
        case .addSuffix(let text):
            return content + text
        case .stripRichText:
            return content  // Handled at ClipboardManager level (clears richTextData)
        case .assignGroup:
            return content  // Group assignment handled at ClipboardManager level
        case .markSensitive:
            return content  // Handled at ClipboardManager level (sets isSensitive)
        case .pin:
            return content  // Handled at ClipboardManager level (sets isPinned)
        case .skipCapture:
            return content  // Handled at ClipboardManager level (skips insert)
        }
    }

    // MARK: - Private Helpers

    private func removeExcessiveBlankLines(_ content: String) -> String {
        // Collapse any consecutive blank lines (2+ newlines) into a single newline
        guard let regex = try? NSRegularExpression(pattern: "\\n{2,}") else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: "\n")
    }

    private func removeMatchingQueryParams(from urlString: String, patterns: [String]) -> String {
        guard var components = URLComponents(string: urlString),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else { return urlString }

        let filtered = queryItems.filter { item in
            !patterns.contains { pattern in
                matchesWildcard(item.name, pattern: pattern)
            }
        }

        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.string ?? urlString
    }

    private func matchesWildcard(_ name: String, pattern: String) -> Bool {
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return name.hasPrefix(prefix)
        }
        return name == pattern
    }

    private func applyRegexReplace(_ content: String, pattern: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let range = NSRange(content.startIndex..., in: content)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: replacement)
    }
}
