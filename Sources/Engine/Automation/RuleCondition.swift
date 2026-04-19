import Foundation

enum RuleCondition: Equatable, Sendable {
    case contentType(ClipContentType)
    /// Matches any text-like content type (text / code / link / color / legacy email, phone).
    /// Useful when a rule should apply to plain text regardless of the specific subtype
    /// that PasteMemo detected.
    case anyText
    case regexMatch(pattern: String)
    case containsText(text: String)
    case sourceApp(bundleIDs: [String])

    func matches(content: String, contentType: ClipContentType, sourceApp: String?) -> Bool {
        switch self {
        case .contentType(let expected):
            return contentType == expected
        case .anyText:
            return contentType.isMergeable
        case .regexMatch(let pattern):
            guard !pattern.isEmpty else { return true }
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(content.startIndex..., in: content)
            return regex.firstMatch(in: content, range: range) != nil
        case .containsText(let text):
            guard !text.isEmpty else { return true }
            return content.localizedCaseInsensitiveContains(text)
        case .sourceApp(let bundleIDs):
            guard !bundleIDs.isEmpty else { return true }
            guard let sourceApp else { return false }
            return bundleIDs.contains(sourceApp)
        }
    }
}

// MARK: - Codable (backward compatible with old sourceApp format)

extension RuleCondition: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case contentType, pattern, text, bundleID, bundleIDs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .contentType(let v):
            try container.encode("contentType", forKey: .type)
            try container.encode(v, forKey: .contentType)
        case .anyText:
            try container.encode("anyText", forKey: .type)
        case .regexMatch(let v):
            try container.encode("regexMatch", forKey: .type)
            try container.encode(v, forKey: .pattern)
        case .containsText(let v):
            try container.encode("containsText", forKey: .type)
            try container.encode(v, forKey: .text)
        case .sourceApp(let v):
            try container.encode("sourceApp", forKey: .type)
            try container.encode(v, forKey: .bundleIDs)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "contentType":
            self = .contentType(try container.decode(ClipContentType.self, forKey: .contentType))
        case "anyText":
            self = .anyText
        case "regexMatch":
            self = .regexMatch(pattern: try container.decode(String.self, forKey: .pattern))
        case "containsText":
            self = .containsText(text: try container.decode(String.self, forKey: .text))
        case "sourceApp":
            // New format: bundleIDs array
            if let ids = try? container.decode([String].self, forKey: .bundleIDs) {
                self = .sourceApp(bundleIDs: ids)
            // Old format: single bundleID string
            } else if let id = try? container.decode(String.self, forKey: .bundleID) {
                self = .sourceApp(bundleIDs: [id])
            } else {
                self = .sourceApp(bundleIDs: [])
            }
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown condition type: \(type)")
        }
    }
}
