import Foundation

/// What a condition is evaluated against. Fields a path doesn't know stay at their
/// defaults: the capture path has no paste target, typed preview text has no source app.
struct ConditionInput {
    var content: String
    var contentType: ClipContentType
    var sourceApp: String?
    /// Bundle ID of the app the result is going to be pasted into. Only the Quick
    /// Panel (⌘K / context menu) and Relay know it; `nil` everywhere else.
    var targetApp: String? = nil
    var isSensitive = false
    var isPinned = false
    var groupName: String? = nil
    var now = Date()
    var calendar = Calendar.current
}

indirect enum RuleCondition: Equatable, Sendable {
    case contentType(ClipContentType)
    /// Matches any text-like content type (text / code / link / color / legacy email, phone).
    /// Useful when a rule should apply to plain text regardless of the specific subtype
    /// that PasteMemo detected.
    case anyText
    case regexMatch(pattern: String)
    case containsText(text: String)
    case sourceApp(bundleIDs: [String])
    /// The app the clip is about to be pasted into. Never matches on capture.
    case targetApp(bundleIDs: [String])
    /// Character count within the bounds; `nil` = unbounded.
    case contentLength(min: Int?, max: Int?)
    /// Line count within the bounds; `nil` = unbounded.
    case lineCount(min: Int?, max: Int?)
    case isSensitive
    case isPinned
    /// In the named group; empty name = in any group.
    case inGroup(name: String)
    /// Local time in [start, end) minutes after midnight; wraps past midnight when
    /// start > end (22:00–07:00).
    case timeOfDay(startMinute: Int, endMinute: Int)
    /// `Calendar` weekday numbers, 1 = Sunday … 7 = Saturday. Empty = every day.
    case weekday(days: [Int])
    case not(RuleCondition)

    func matches(content: String, contentType: ClipContentType, sourceApp: String?) -> Bool {
        matches(ConditionInput(content: content, contentType: contentType, sourceApp: sourceApp))
    }

    func matches(_ input: ConditionInput) -> Bool {
        switch self {
        case .contentType(let expected):
            return input.contentType == expected
        case .anyText:
            return input.contentType.isMergeable
        case .regexMatch(let pattern):
            guard !pattern.isEmpty else { return true }
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(input.content.startIndex..., in: input.content)
            return regex.firstMatch(in: input.content, range: range) != nil
        case .containsText(let text):
            guard !text.isEmpty else { return true }
            return input.content.localizedCaseInsensitiveContains(text)
        case .sourceApp(let bundleIDs):
            guard !bundleIDs.isEmpty else { return true }
            guard let sourceApp = input.sourceApp else { return false }
            return bundleIDs.contains(sourceApp)
        case .targetApp(let bundleIDs):
            guard !bundleIDs.isEmpty else { return true }
            guard let targetApp = input.targetApp else { return false }
            return bundleIDs.contains(targetApp)
        case .contentLength(let min, let max):
            return Self.within(input.content.count, min: min, max: max)
        case .lineCount(let min, let max):
            return Self.within(Self.lineCount(of: input.content), min: min, max: max)
        case .isSensitive:
            return input.isSensitive
        case .isPinned:
            return input.isPinned
        case .inGroup(let name):
            guard let group = input.groupName, !group.isEmpty else { return false }
            return name.isEmpty || group == name
        case .timeOfDay(let start, let end):
            let parts = input.calendar.dateComponents([.hour, .minute], from: input.now)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if start == end { return true }
            return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
        case .weekday(let days):
            guard !days.isEmpty else { return true }
            return days.contains(input.calendar.component(.weekday, from: input.now))
        case .not(let inner):
            return !inner.matches(input)
        }
    }

    /// The condition without its negation, and whether it was negated. The editor
    /// shows a negated condition as the plain one plus a "not" switch.
    var unwrappedNegation: (base: RuleCondition, negated: Bool) {
        guard case .not(let inner) = self else { return (self, false) }
        let (base, negated) = inner.unwrappedNegation
        return (base, !negated)
    }

    /// Conditions about the clip as stored (source app, state) or the paste target.
    /// Text typed into the editor's preview box has none of these, so the preview
    /// leaves them out instead of always reporting "not matched".
    var needsClipContext: Bool {
        switch unwrappedNegation.base {
        case .sourceApp, .targetApp, .isSensitive, .isPinned, .inGroup: return true
        default: return false
        }
    }

    static func lineCount(of text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.components(separatedBy: .newlines).count
    }

    private static func within(_ value: Int, min: Int?, max: Int?) -> Bool {
        if let min, value < min { return false }
        if let max, value > max { return false }
        return true
    }
}

// MARK: - Codable (backward compatible with old sourceApp format)

extension RuleCondition: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case contentType, pattern, text, bundleID, bundleIDs
        case min, max, name, start, end, days, condition
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
        case .targetApp(let v):
            try container.encode("targetApp", forKey: .type)
            try container.encode(v, forKey: .bundleIDs)
        case .contentLength(let min, let max):
            try container.encode("contentLength", forKey: .type)
            try container.encodeIfPresent(min, forKey: .min)
            try container.encodeIfPresent(max, forKey: .max)
        case .lineCount(let min, let max):
            try container.encode("lineCount", forKey: .type)
            try container.encodeIfPresent(min, forKey: .min)
            try container.encodeIfPresent(max, forKey: .max)
        case .isSensitive:
            try container.encode("isSensitive", forKey: .type)
        case .isPinned:
            try container.encode("isPinned", forKey: .type)
        case .inGroup(let name):
            try container.encode("inGroup", forKey: .type)
            try container.encode(name, forKey: .name)
        case .timeOfDay(let start, let end):
            try container.encode("timeOfDay", forKey: .type)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        case .weekday(let days):
            try container.encode("weekday", forKey: .type)
            try container.encode(days, forKey: .days)
        case .not(let inner):
            try container.encode("not", forKey: .type)
            try container.encode(inner, forKey: .condition)
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
        case "targetApp":
            self = .targetApp(bundleIDs: try container.decode([String].self, forKey: .bundleIDs))
        case "contentLength":
            self = .contentLength(min: try container.decodeIfPresent(Int.self, forKey: .min),
                                  max: try container.decodeIfPresent(Int.self, forKey: .max))
        case "lineCount":
            self = .lineCount(min: try container.decodeIfPresent(Int.self, forKey: .min),
                              max: try container.decodeIfPresent(Int.self, forKey: .max))
        case "isSensitive":
            self = .isSensitive
        case "isPinned":
            self = .isPinned
        case "inGroup":
            self = .inGroup(name: try container.decode(String.self, forKey: .name))
        case "timeOfDay":
            self = .timeOfDay(startMinute: try container.decode(Int.self, forKey: .start),
                              endMinute: try container.decode(Int.self, forKey: .end))
        case "weekday":
            self = .weekday(days: try container.decode([Int].self, forKey: .days))
        case "not":
            self = .not(try container.decode(RuleCondition.self, forKey: .condition))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown condition type: \(type)")
        }
    }
}
